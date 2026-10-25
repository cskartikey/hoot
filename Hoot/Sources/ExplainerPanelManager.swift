//
//  ExplainerPanelManager.swift
//  Hoot
//
//  Owns the floating explainer panel that appears bottom-right when the
//  tutor decides a picture would help. Two kinds of picture share it:
//    - [VIDEO:brief]: a studio job (narrated Manim video). Publishes live
//      progress (which of script / voice / animate / stitch is running, the
//      video title) for ExplainerPanelView, and once the video is ready
//      drives an AVPlayer plus synced captions, play/pause and the scrubber.
//    - [SKETCH:brief]: one LLM call for an animated SVG page, shown in a
//      web view within seconds (ExplainerSketchClient / ExplainerSketchView).
//
//  Uses the same borderless, non-activating NSPanel pattern as
//  the menu bar and overlay panels so it floats above every app, joins all
//  Spaces, and never steals focus from whatever the user is learning in.
//  ScreenCapturer already excludes every window owned by this
//  app, so the panel never shows up in the screenshots sent to Claude.
//
//  The panel window is sized to fit the SwiftUI content (the card, plus the
//  pet perched above it while the video plays, plus room for the soft
//  shadow). Fully transparent pixels of a non-opaque borderless window let
//  clicks through to the app below, and the window is kept tight around the
//  card so the transparent margin stays small.
//

import AppKit
import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Where the explainer panel is in its lifecycle. `generatingVideo` covers
/// both kinds of job (see `isActiveJobASketch` for which).
enum ExplainerPanelPhase: Equatable {
    case generatingVideo
    case playingVideo(StudioFinishedVideo)
    case showingSketch(ExplainerFinishedSketch)
    case failed(friendlyErrorMessage: String)

    /// True while a finished picture (either kind) is on the card.
    var isShowingAPicture: Bool {
        switch self {
        case .playingVideo, .showingSketch: return true
        case .generatingVideo, .failed: return false
        }
    }
}

/// The four segments of the rendering progress bar. The studio sends stage
/// events for script, voice and render; it sends no event for the final mux
/// ("stitch"), so the view estimates when animating has turned into stitching.
enum ExplainerProgressStep: Int, CaseIterable {
    case script
    case voice
    case animate
    case stitch

    /// Label under the progress segment.
    var segmentLabel: String {
        switch self {
        case .script: return "script"
        case .voice: return "voice"
        case .animate: return "animate"
        case .stitch: return "stitch"
        }
    }

    /// Typical seconds each step takes, from the studio's job.json timings
    /// (script ~11s, voice ~1s, scene code + render ~33s, mux ~2–4s).
    /// Drives the ETA countdown and the partial fill of the active segment.
    var typicalDurationInSeconds: Double {
        switch self {
        case .script: return 11
        case .voice: return 1.5
        case .animate: return 33
        case .stitch: return 3
        }
    }
}

@MainActor
final class ExplainerPanelManager: ObservableObject {

    // MARK: - Published state for ExplainerPanelView

    @Published private(set) var explainerPanelPhase: ExplainerPanelPhase = .generatingVideo
    /// Whether the panel is on screen at all, in any phase (rendering, playing,
    /// sketch, failed). The phase alone can't say: it is `.generatingVideo`
    /// even while the panel is hidden. The overlay pet, the nudges and
    /// "just do it" all key off this, because the panel occupies the
    /// bottom-right corner and shows its own perched pet in every phase.
    @Published private(set) var isExplainerPanelOpen: Bool = false
    @Published private(set) var currentQuestionText: String = ""
    /// Title from the studio's `script` event; nil until the script is written.
    @Published private(set) var studioScriptTitleText: String?

    /// The latest step the studio reported, and when it started. The view
    /// combines these with the clock for the ETA and the active segment fill.
    @Published private(set) var latestReportedProgressStep: ExplainerProgressStep = .script
    @Published private(set) var latestReportedProgressStepStartedDate: Date = Date()
    /// 1 for the first render; 2+ while the studio is fixing a broken scene.
    @Published private(set) var currentRenderAttemptNumber: Int = 1
    /// True until the studio's first stage event arrives (the POST is in flight).
    @Published private(set) var isWaitingForFirstStudioStage: Bool = true
    /// True while the job in the panel is a sketch (one LLM call) rather
    /// than a studio video; the rendering view shows a different pill and ETA.
    @Published private(set) var isActiveJobASketch: Bool = false
    /// When the sketch call started, for the rendering view's ETA.
    @Published private(set) var sketchJobStartedDate: Date = Date()
    /// Typical wall time for a sketch (one ~2k-token reply), for the ETA.
    static let typicalSketchDurationInSeconds: Double = 12

    @Published private(set) var explainerVideoPlayer: AVPlayer?
    /// The finished video's address, for opening it in the large window.
    private var currentFinishedVideoURL: URL?
    private var largeExplainerVideoWindow: NSWindow?
    /// The big window's own player; must be stopped when that window closes,
    /// otherwise its audio keeps playing with nothing on screen.
    private var largeExplainerVideoPlayer: AVPlayer?
    private var largeWindowCloseObserver: NSObjectProtocol?
    private var currentVideoTitleForLargeWindow = "hoot"
    @Published private(set) var currentCaptionText: String?
    @Published private(set) var hasVideoFinishedPlaying: Bool = false
    @Published private(set) var isVideoPlaying: Bool = false
    @Published private(set) var currentPlaybackTimeInSeconds: Double = 0
    @Published private(set) var finishedVideoDurationInSeconds: Double = 0
    /// Local-only bookmark toggle for the current video (not persisted yet).
    @Published private(set) var isCurrentVideoBookmarked: Bool = false

    // MARK: - Layout

    static let explainerCardWidth: CGFloat = 318
    /// How far above the card's top edge the 96pt pet sprite starts. The
    /// design perches the pet so its feet overlap the card's top border.
    static let presentingPetOverhangAboveCard: CGFloat = 82
    static let presentingPetInsetFromCardLeadingEdge: CGFloat = 22
    /// Transparent room around the card so its soft shadow (y 16, blur 24)
    /// renders instead of being clipped by the window edge.
    static let shadowPaddingOnSides: CGFloat = 28
    static let shadowPaddingAboveCard: CGFloat = 12
    static let shadowPaddingBelowCard: CGFloat = 40
    static var explainerPanelWindowWidth: CGFloat {
        explainerCardWidth + shadowPaddingOnSides * 2
    }
    private let marginFromScreenEdge: CGFloat = 16

    // MARK: - Private state

    private let studioClient = StudioClient()
    private let sketchClient = ExplainerSketchClient()
    private var explainerPanel: NSPanel?
    /// The job the panel is showing progress for: a studio job or a sketch
    /// call (the name predates sketches; both use the same slot).
    private var activeStudioJobTask: Task<Void, Never>?
    private var localEscapeKeyMonitor: Any?
    private var globalEscapeKeyMonitor: Any?
    private var playbackTimeObserverToken: Any?
    private var playbackEndedObserver: NSObjectProtocol?
    private var finishedVideoCaptions: [StudioCaption] = []
    private var mostRecentExplainerVideoRequest: HootController.ExplainerVideoRequest?
    private var themeAppearanceCancellable: AnyCancellable?

    /// True once the user closed the panel while the active studio job was
    /// still rendering (or switched to a saved video over it): the job keeps
    /// going without touching the panel, and its finished video is offered
    /// through `onVideoReadyWhileClosed` instead of reopening the panel.
    private var isActiveJobRunningInBackground = false
    /// The active job's best title so far (the question, then the studio's
    /// script title), kept apart from the published UI text so a job running
    /// in the background never overwrites what the panel is showing.
    private var activeJobVideoTitle = ""

    private static let escapeKeyCode: UInt16 = 53

    /// The one manager the app delegate creates, so views that only get the
    /// HootController (the menu bar panel) can reopen saved videos. Weak so
    /// it never keeps a discarded manager alive.
    private(set) static weak var shared: ExplainerPanelManager?

    init() {
        Self.shared = self
        // Keep the panel's NSAppearance in step with the theme so the
        // `.ultraThinMaterial` behind the glass tint matches light/dark.
        // `$theme` fires before the store's value changes, so use the new value.
        themeAppearanceCancellable = WaitWhatThemeStore.shared.$theme
            .sink { [weak self] newTheme in
                self?.explainerPanel?.appearance = NSAppearance(named: newTheme.isDark ? .darkAqua : .aqua)
            }
    }

    // MARK: - Public API

    /// Shows the panel (creating it on first use) and starts a fresh studio
    /// job. Any job already in flight is cancelled so only the newest
    /// question's video is shown.
    func showAndGenerate(request explainerVideoRequest: HootController.ExplainerVideoRequest) {
        // A new request always replaces the previous job, even one that was
        // left rendering in the background.
        cancelActiveJobAndPlayback()
        mostRecentExplainerVideoRequest = explainerVideoRequest
        isActiveJobRunningInBackground = false
        activeJobVideoTitle = explainerVideoRequest.question

        currentQuestionText = explainerVideoRequest.question
        studioScriptTitleText = nil
        latestReportedProgressStep = .script
        latestReportedProgressStepStartedDate = Date()
        currentRenderAttemptNumber = 1
        isWaitingForFirstStudioStage = true
        currentCaptionText = nil
        hasVideoFinishedPlaying = false
        isVideoPlaying = false
        currentPlaybackTimeInSeconds = 0
        finishedVideoDurationInSeconds = 0
        isCurrentVideoBookmarked = false
        isActiveJobASketch = explainerVideoRequest.kind == .sketch
        sketchJobStartedDate = Date()
        explainerPanelPhase = .generatingVideo

        showPanelAtBottomRightOfMouseScreen()
        installEscapeKeyMonitors()

        if explainerVideoRequest.kind == .sketch {
            activeStudioJobTask = Task { [weak self] in
                await self?.runSketchJob(request: explainerVideoRequest)
            }
            return
        }

        // Captured now (not when the request lands) so it reflects the app the
        // user was in when they asked, e.g. "Google Chrome" for a YouTube lecture.
        let frontmostApplicationName = NSWorkspace.shared.frontmostApplication?.localizedName

        let explainRequestBody = StudioExplainRequestBody(
            question: explainerVideoRequest.question,
            brief: explainerVideoRequest.brief,
            spokenAnswer: explainerVideoRequest.spokenAnswer,
            context: StudioExplainContext(app: frontmostApplicationName, youtube: explainerVideoRequest.youTubeContext, screenText: nil),
            memory: []
        )

        activeStudioJobTask = Task { [weak self] in
            await self?.runStudioJob(explainRequestBody: explainRequestBody)
        }
    }

    /// Called after the panel closes, so the YouTube video paused for the
    /// question can resume.
    var onExplainerPanelClosed: (() -> Void)?

    // MARK: - Memory hooks (SKELETON — owned by the panel agent)

    /// Called with the finished video's URL whenever a studio job completes,
    /// so memory can attach it to the question that asked for it.
    var onFinishedVideoReady: ((String) -> Void)?
    /// Called when a video finishes after the user closed the panel mid-render
    /// (url, title), so a corner nudge can offer it.
    var onVideoReadyWhileClosed: ((String, String) -> Void)?

    /// Opens the panel straight into playback of a saved video (from the
    /// menu panel's recent list or a "video ready" nudge). Saved videos have
    /// no captions, so the caption line shows the title instead. A job that
    /// is still rendering keeps going in the background and is offered
    /// through `onVideoReadyWhileClosed` when it finishes.
    func playSavedVideo(url savedVideoURLString: String, title savedVideoTitle: String) {
        // Saved sketches share the memory slot with saved videos; the file
        // type tells them apart.
        if let savedURL = URL(string: savedVideoURLString), savedURL.pathExtension.lowercased() == "html" {
            showSavedSketch(fileURL: savedURL, title: savedVideoTitle)
            return
        }
        moveRenderingJobToBackgroundIfAny()
        stopPlayback()
        stopLargeWindowPlayback()

        currentQuestionText = savedVideoTitle
        studioScriptTitleText = savedVideoTitle
        currentVideoTitleForLargeWindow = savedVideoTitle.lowercased()
        hasVideoFinishedPlaying = false
        isCurrentVideoBookmarked = false

        let savedFinishedVideo = StudioFinishedVideo(url: savedVideoURLString, duration: 0, captions: [], fallback: false)
        startPlayback(finishedVideo: savedFinishedVideo)
        if case .playingVideo = explainerPanelPhase {
            currentCaptionText = savedVideoTitle
            loadDurationOfCurrentVideo()
        }

        showPanelAtBottomRightOfMouseScreen()
        installEscapeKeyMonitors()
    }

    /// The saved video's length isn't stored, so read it from the file once
    /// the asset loads (the scrubber and the time label need it).
    private func loadDurationOfCurrentVideo() {
        guard let currentFinishedVideoURL else { return }
        let videoURLWhenAsked = currentFinishedVideoURL
        Task { [weak self] in
            let loadedDuration = try? await AVURLAsset(url: videoURLWhenAsked).load(.duration)
            guard let self, let loadedDuration, loadedDuration.seconds.isFinite,
                  self.currentFinishedVideoURL == videoURLWhenAsked else { return }
            self.finishedVideoDurationInSeconds = loadedDuration.seconds
        }
    }

    /// Closing (×, Esc) while the video is still rendering hides the panel
    /// but lets the studio finish; the finished video is then offered with a
    /// nudge instead of popping the panel back open.
    func close() {
        onExplainerPanelClosed?()
        moveRenderingJobToBackgroundIfAny()
        // Not cancelActiveJobAndPlayback: that would also cancel the job we
        // just moved to the background.
        activeStudioJobTask?.cancel()
        activeStudioJobTask = nil
        stopPlayback()
        // Closing the panel ends the video everywhere, big window included.
        stopLargeWindowPlayback()
        largeExplainerVideoWindow?.orderOut(nil)
        removeEscapeKeyMonitors()
        explainerPanel?.orderOut(nil)
        isExplainerPanelOpen = false
    }

    /// "try again" from the error state: rerun the same request.
    func retryMostRecentRequest() {
        guard let mostRecentExplainerVideoRequest else { return }
        showAndGenerate(request: mostRecentExplainerVideoRequest)
    }

    func replayExplainerVideo() {
        guard let explainerVideoPlayer else { return }
        hasVideoFinishedPlaying = false
        currentPlaybackTimeInSeconds = 0
        explainerVideoPlayer.seek(to: .zero)
        explainerVideoPlayer.play()
        isVideoPlaying = true
    }

    /// The play/pause control: pauses, resumes, or replays once finished.
    func togglePlayPauseOrReplay() {
        guard let explainerVideoPlayer else { return }
        if hasVideoFinishedPlaying {
            replayExplainerVideo()
        } else if isVideoPlaying {
            explainerVideoPlayer.pause()
            isVideoPlaying = false
        } else {
            explainerVideoPlayer.play()
            isVideoPlaying = true
        }
    }

    /// Opens the current video in a big, resizable window with standard
    /// controls (including fullscreen), continuing from where the panel was.
    func openExplainerVideoInLargeWindow() {
        if case .showingSketch(let finishedSketch) = explainerPanelPhase {
            openSketchInLargeWindow(finishedSketch)
            return
        }
        guard let currentFinishedVideoURL else { return }
        let resumeTime = explainerVideoPlayer?.currentTime() ?? .zero
        explainerVideoPlayer?.pause()
        isVideoPlaying = false

        stopLargeWindowPlayback()
        let largeVideoPlayer = AVPlayer(url: currentFinishedVideoURL)
        largeVideoPlayer.seek(to: resumeTime)
        largeExplainerVideoPlayer = largeVideoPlayer

        let largePlayerView = AVPlayerView()
        largePlayerView.player = largeVideoPlayer
        largePlayerView.controlsStyle = .floating
        largePlayerView.showsFullScreenToggleButton = true

        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let windowWidth = min(1120, visibleFrame.width * 0.8)
        let windowContentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowWidth * 9 / 16)

        let largeVideoWindow = largeExplainerVideoWindow ?? NSWindow(
            contentRect: windowContentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        largeVideoWindow.isReleasedWhenClosed = false
        largeVideoWindow.title = currentVideoTitleForLargeWindow
        largeVideoWindow.contentAspectRatio = NSSize(width: 16, height: 9)
        largeVideoWindow.contentView = largePlayerView
        largeVideoWindow.setContentSize(windowContentRect.size)
        largeVideoWindow.center()
        largeExplainerVideoWindow = largeVideoWindow
        if largeWindowCloseObserver == nil {
            largeWindowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: largeVideoWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopLargeWindowPlayback() }
            }
        }

        // A menu-bar app has to activate to put a normal window in front.
        NSApp.activate(ignoringOtherApps: true)
        largeVideoWindow.makeKeyAndOrderFront(nil)
        largeVideoPlayer.play()
    }

    /// The same big window the video player uses, holding a second web
    /// view on the sketch page over a theme-colored background (the card's
    /// glass isn't there to show through).
    private func openSketchInLargeWindow(_ finishedSketch: ExplainerFinishedSketch) {
        stopLargeWindowPlayback()

        let theme = WaitWhatThemeStore.shared.theme
        let largeSketchHostingView = NSHostingView(rootView:
            ExplainerSketchView(sketchFileURL: finishedSketch.fileURL)
                .padding(24)
                .background(theme.pageBackground)
        )

        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let windowWidth = min(1120, visibleFrame.width * 0.8)
        let windowContentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowWidth * 9 / 16)

        let largeSketchWindow = largeExplainerVideoWindow ?? NSWindow(
            contentRect: windowContentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        largeSketchWindow.isReleasedWhenClosed = false
        largeSketchWindow.title = currentVideoTitleForLargeWindow
        largeSketchWindow.contentAspectRatio = NSSize(width: 16, height: 9)
        // The page's prefers-color-scheme follows the window's appearance.
        largeSketchWindow.appearance = WaitWhatThemeStore.shared.nsAppearance
        largeSketchWindow.contentView = largeSketchHostingView
        largeSketchWindow.setContentSize(windowContentRect.size)
        largeSketchWindow.center()
        largeExplainerVideoWindow = largeSketchWindow

        NSApp.activate(ignoringOtherApps: true)
        largeSketchWindow.makeKeyAndOrderFront(nil)
    }

    private func stopLargeWindowPlayback() {
        largeExplainerVideoPlayer?.pause()
        largeExplainerVideoPlayer = nil
        (largeExplainerVideoWindow?.contentView as? AVPlayerView)?.player = nil
    }

    func toggleCurrentVideoBookmark() {
        isCurrentVideoBookmarked.toggle()
    }

    /// Called by the view whenever its laid-out size changes. Resizes the
    /// window to fit while keeping its bottom-right corner where it is, so
    /// the card stays anchored to the screen corner (or wherever the user
    /// dragged it) as it grows for the perched pet or a longer caption.
    func resizePanelToFitContent(contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        // Never resize the window from inside SwiftUI's layout pass: setFrame
        // there triggers another layout pass, and with animated content the
        // two can feed each other until AppKit throws "more Update Constraints
        // in Window passes than there are views". Remember the latest height
        // and apply it once, after the current pass, rounded to whole points.
        pendingPanelContentHeight = contentHeight.rounded(.up)
        guard !isPanelResizeScheduled else { return }
        isPanelResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingPanelResize()
        }
    }

    private var pendingPanelContentHeight: CGFloat?
    private var isPanelResizeScheduled = false

    private func applyPendingPanelResize() {
        isPanelResizeScheduled = false
        guard let explainerPanel, let pendingPanelContentHeight else { return }
        self.pendingPanelContentHeight = nil
        let currentPanelFrame = explainerPanel.frame
        guard abs(currentPanelFrame.height - pendingPanelContentHeight) >= 1 else { return }
        let resizedPanelFrame = NSRect(
            x: currentPanelFrame.maxX - Self.explainerPanelWindowWidth,
            y: currentPanelFrame.minY,
            width: Self.explainerPanelWindowWidth,
            height: pendingPanelContentHeight
        )
        explainerPanel.setFrame(resizedPanelFrame, display: true, animate: false)
    }

    // MARK: - Sketch job

    /// One LLM call (with one retry inside the client), then the page goes
    /// on the card. Mirrors `runStudioJob` for the background / failure
    /// bookkeeping so closing the panel mid-sketch behaves the same way.
    private func runSketchJob(request sketchRequest: HootController.ExplainerVideoRequest) async {
        do {
            let finishedSketch = try await sketchClient.makeSketch(
                brief: sketchRequest.brief,
                question: sketchRequest.question,
                spokenAnswer: sketchRequest.spokenAnswer
            )
            if Task.isCancelled { return }
            onFinishedVideoReady?(finishedSketch.fileURL.absoluteString)
            if isActiveJobRunningInBackground {
                let finishedSketchTitle = activeJobVideoTitle
                finishBackgroundJob()
                onVideoReadyWhileClosed?(finishedSketch.fileURL.absoluteString, finishedSketchTitle)
                return
            }
            activeStudioJobTask = nil
            showSketch(finishedSketch)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            print("⚠️ Sketch failed: \(error)")
            if isActiveJobRunningInBackground {
                finishBackgroundJob()
                return
            }
            explainerPanelPhase = .failed(friendlyErrorMessage: Self.friendlySketchErrorMessage(for: error))
        }
    }

    /// Puts a finished sketch on the card. The caption line (which videos
    /// use for synced captions) shows the question the sketch answers.
    private func showSketch(_ finishedSketch: ExplainerFinishedSketch) {
        stopPlayback()
        currentFinishedVideoURL = nil
        currentVideoTitleForLargeWindow = finishedSketch.question.lowercased()
        currentCaptionText = finishedSketch.question.lowercased()
        hasVideoFinishedPlaying = false
        explainerPanelPhase = .showingSketch(finishedSketch)
    }

    /// A saved sketch from memory or a "ready while you were away" nudge:
    /// straight onto the card, like `playSavedVideo` for videos.
    private func showSavedSketch(fileURL savedSketchFileURL: URL, title savedSketchTitle: String) {
        moveRenderingJobToBackgroundIfAny()
        stopPlayback()
        stopLargeWindowPlayback()

        currentQuestionText = savedSketchTitle
        studioScriptTitleText = savedSketchTitle
        isCurrentVideoBookmarked = false
        showSketch(ExplainerFinishedSketch(fileURL: savedSketchFileURL, question: savedSketchTitle, brief: ""))

        showPanelAtBottomRightOfMouseScreen()
        installEscapeKeyMonitors()
    }

    private static func friendlySketchErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError,
           urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
            return "hoot's worker isn't running right now, so i can't draw this one."
        }
        if error is ExplainerSketchError {
            return "my sketch came out wrong twice in a row. ask me again and i'll take another shot."
        }
        return "something went wrong while sketching. ask me again in a moment."
    }

    // MARK: - Studio job

    private func runStudioJob(explainRequestBody: StudioExplainRequestBody) async {
        do {
            let studioJobId = try await studioClient.startExplainerJob(explainRequestBody: explainRequestBody)
            print("🎬 Studio job started: \(studioJobId)")

            for try await studioJobEvent in studioClient.streamJobEvents(jobId: studioJobId) {
                if Task.isCancelled { return }
                handleStudioJobEvent(studioJobEvent)
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            print("⚠️ Studio job failed: \(error)")
            if isActiveJobRunningInBackground {
                // Nobody is looking; don't pop an error panel up later.
                finishBackgroundJob()
                return
            }
            explainerPanelPhase = .failed(friendlyErrorMessage: Self.friendlyErrorMessage(for: error))
        }
    }

    private func handleStudioJobEvent(_ studioJobEvent: StudioJobEvent) {
        switch studioJobEvent {
        case .stage(let stageUpdate):
            guard !isActiveJobRunningInBackground else { return }
            handleStudioStageUpdate(stageUpdate)
        case .script(let studioScript):
            if let studioScriptTitle = studioScript.title, !studioScriptTitle.isEmpty {
                activeJobVideoTitle = studioScriptTitle
                guard !isActiveJobRunningInBackground else { return }
                currentVideoTitleForLargeWindow = studioScriptTitle.lowercased()
                studioScriptTitleText = studioScriptTitle
            }
        case .done(let finishedVideo):
            onFinishedVideoReady?(finishedVideo.url)
            if isActiveJobRunningInBackground {
                let finishedVideoTitle = activeJobVideoTitle
                finishBackgroundJob()
                onVideoReadyWhileClosed?(finishedVideo.url, finishedVideoTitle)
                return
            }
            activeStudioJobTask = nil
            startPlayback(finishedVideo: finishedVideo)
        case .error(let studioErrorMessage):
            print("⚠️ Studio reported error: \(studioErrorMessage)")
            if isActiveJobRunningInBackground {
                finishBackgroundJob()
                return
            }
            explainerPanelPhase = .failed(friendlyErrorMessage: "i couldn't finish that animation this time. ask me again and i'll take another shot.")
        }
    }

    /// If a job is still rendering, detach it from the panel so it keeps
    /// running while the panel closes or shows something else.
    private func moveRenderingJobToBackgroundIfAny() {
        guard activeStudioJobTask != nil, explainerPanelPhase == .generatingVideo else { return }
        isActiveJobRunningInBackground = true
        backgroundStudioJobTask = activeStudioJobTask
        activeStudioJobTask = nil
    }

    private func finishBackgroundJob() {
        isActiveJobRunningInBackground = false
        backgroundStudioJobTask = nil
    }

    /// The job left running after the panel closed. Kept separately from
    /// `activeStudioJobTask` so closing/stopping playback leaves it alone;
    /// only a new request cancels it.
    private var backgroundStudioJobTask: Task<Void, Never>?

    /// Maps the studio's stage names onto the four progress segments:
    /// `script` → script, `voice` → voice, `render` (any attempt) → animate.
    /// Stitch has no event; the view switches to it once animating has run
    /// about as long as a render usually takes.
    private func handleStudioStageUpdate(_ stageUpdate: StudioStageUpdate) {
        let reportedProgressStep: ExplainerProgressStep
        switch stageUpdate.stage {
        case "script":
            reportedProgressStep = .script
        case "voice":
            reportedProgressStep = .voice
        case "render":
            reportedProgressStep = .animate
            currentRenderAttemptNumber = stageUpdate.attempt ?? 1
        default:
            print("🎬 Unknown studio stage: \(stageUpdate.stage)")
            return
        }
        isWaitingForFirstStudioStage = false
        latestReportedProgressStep = reportedProgressStep
        latestReportedProgressStepStartedDate = Date()
    }

    private static func friendlyErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError,
           urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
            return "the video studio isn't running right now, so i can't draw this one."
        }
        return "something went wrong while making the video. ask me again in a moment."
    }

    // MARK: - Playback

    private func startPlayback(finishedVideo: StudioFinishedVideo) {
        guard let finishedVideoURL = URL(string: finishedVideo.url) else {
            explainerPanelPhase = .failed(friendlyErrorMessage: "the video came back in a shape i can't play.")
            return
        }

        currentFinishedVideoURL = finishedVideoURL
        finishedVideoCaptions = finishedVideo.captions
        finishedVideoDurationInSeconds = finishedVideo.duration
        currentPlaybackTimeInSeconds = 0
        let newExplainerVideoPlayer = AVPlayer(url: finishedVideoURL)

        // Poll playback time ~10x/second for the scrubber, the time label and
        // whichever caption covers it. Captions are rendered by the panel
        // (not burned into the video) so they stay crisp at any size.
        playbackTimeObserverToken = newExplainerVideoPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] currentPlaybackTime in
            // Delivered on the main queue, so we are already on the main actor.
            MainActor.assumeIsolated {
                self?.updatePlaybackProgress(playbackTimeInSeconds: currentPlaybackTime.seconds)
            }
        }

        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newExplainerVideoPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasVideoFinishedPlaying = true
                self.isVideoPlaying = false
                self.currentPlaybackTimeInSeconds = self.finishedVideoDurationInSeconds
            }
        }

        explainerVideoPlayer = newExplainerVideoPlayer
        // Start with the first caption so the caption line is never empty.
        currentCaptionText = finishedVideoCaptions.first?.text
        explainerPanelPhase = .playingVideo(finishedVideo)
        newExplainerVideoPlayer.play()
        isVideoPlaying = true
    }

    private func updatePlaybackProgress(playbackTimeInSeconds: Double) {
        guard playbackTimeInSeconds.isFinite else { return }
        if !hasVideoFinishedPlaying {
            currentPlaybackTimeInSeconds = playbackTimeInSeconds
        }

        // Between captions (and after the last one) keep the previous line
        // up rather than flashing an empty caption area.
        let activeCaption = finishedVideoCaptions.first { caption in
            caption.start <= playbackTimeInSeconds && playbackTimeInSeconds < caption.end
        }
        if let activeCaption, currentCaptionText != activeCaption.text {
            currentCaptionText = activeCaption.text
        }
    }

    /// Cancels every studio job (active or in the background) and stops
    /// playback. Used when a new request replaces whatever came before.
    private func cancelActiveJobAndPlayback() {
        activeStudioJobTask?.cancel()
        activeStudioJobTask = nil
        backgroundStudioJobTask?.cancel()
        backgroundStudioJobTask = nil
        isActiveJobRunningInBackground = false
        stopPlayback()
    }

    private func stopPlayback() {
        if let explainerVideoPlayer {
            explainerVideoPlayer.pause()
            if let playbackTimeObserverToken {
                explainerVideoPlayer.removeTimeObserver(playbackTimeObserverToken)
            }
        }
        playbackTimeObserverToken = nil
        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
        }
        playbackEndedObserver = nil

        explainerVideoPlayer = nil
        isVideoPlaying = false
        finishedVideoCaptions = []
    }

    // MARK: - Panel

    private func showPanelAtBottomRightOfMouseScreen() {
        if explainerPanel == nil {
            createExplainerPanel()
        }
        guard let explainerPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        if let visibleFrameOfScreenWithMouse = screenWithMouse?.visibleFrame {
            let panelSize = explainerPanel.frame.size
            // The shadow padding is transparent, so subtract it to put the
            // visible card (not the invisible panel edge) near the screen corner.
            let panelOriginX = visibleFrameOfScreenWithMouse.maxX - panelSize.width
                - marginFromScreenEdge + Self.shadowPaddingOnSides
            let panelOriginY = visibleFrameOfScreenWithMouse.minY
                + marginFromScreenEdge - Self.shadowPaddingBelowCard
            explainerPanel.setFrameOrigin(NSPoint(x: panelOriginX, y: panelOriginY))
        }

        explainerPanel.appearance = WaitWhatThemeStore.shared.nsAppearance

        // orderFrontRegardless (not makeKeyAndOrderFront) so the panel appears
        // without taking keyboard focus away from the user's app.
        explainerPanel.orderFrontRegardless()
        isExplainerPanelOpen = true
    }

    private func createExplainerPanel() {
        let panelWidth = Self.explainerPanelWindowWidth
        // A first guess at the rendering state's height; the view reports its
        // real height right after layout and the panel resizes to fit.
        let initialPanelHeight: CGFloat = 320

        let hostingView = NSHostingView(rootView: ExplainerPanelView(explainerPanelManager: self))
        // The panel size is driven by resizePanelToFitContent, not by Auto
        // Layout constraints from the SwiftUI content.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: initialPanelHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let newExplainerPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: initialPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newExplainerPanel.isFloatingPanel = true
        newExplainerPanel.level = .floating
        newExplainerPanel.isOpaque = false
        newExplainerPanel.backgroundColor = .clear
        // The SwiftUI card draws its own soft shadow; the window shadow would
        // outline the transparent padding as a hard rectangle.
        newExplainerPanel.hasShadow = false
        newExplainerPanel.hidesOnDeactivate = false
        newExplainerPanel.isExcludedFromWindowsMenu = true
        newExplainerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newExplainerPanel.isMovableByWindowBackground = true
        newExplainerPanel.appearance = WaitWhatThemeStore.shared.nsAppearance
        newExplainerPanel.contentView = hostingView

        explainerPanel = newExplainerPanel
    }

    // MARK: - Escape key

    /// The local monitor handles Esc when our app happens to be active; the
    /// global monitor handles it while the user is in another app (the normal
    /// case, since the panel is non-activating). Global key monitoring relies
    /// on the Accessibility permission the app already requests.
    private func installEscapeKeyMonitors() {
        removeEscapeKeyMonitors()

        localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyDownEvent in
            guard keyDownEvent.keyCode == Self.escapeKeyCode else { return keyDownEvent }
            Task { @MainActor in self?.close() }
            return nil
        }

        globalEscapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] keyDownEvent in
            guard keyDownEvent.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in self?.close() }
        }
    }

    private func removeEscapeKeyMonitors() {
        if let localEscapeKeyMonitor {
            NSEvent.removeMonitor(localEscapeKeyMonitor)
        }
        localEscapeKeyMonitor = nil
        if let globalEscapeKeyMonitor {
            NSEvent.removeMonitor(globalEscapeKeyMonitor)
        }
        globalEscapeKeyMonitor = nil
    }
}
