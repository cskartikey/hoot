//
//  HootApp.swift
//  Hoot
//
//  Menu-bar-only app entry point: creates the HootController, the menu bar
//  controller, the pet overlay and the explainer panel, and wires them
//  together.
//

import AppKit
import Combine
import SwiftUI

@main
struct HootApp: App {
    @NSApplicationDelegateAdaptor(HootAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class HootAppDelegate: NSObject, NSApplicationDelegate {
    private var hootController: HootController?
    private var menuBarController: MenuBarController?
    private var petOverlayManager: PetOverlayManager?
    private var explainerPanelManager: ExplainerPanelManager?
    private var hasShownPetOverlays = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        WaitWhatFonts.registerBundledFonts()

        let hootController = HootController()
        let explainerPanelManager = ExplainerPanelManager()
        let petOverlayManager = PetOverlayManager(hootController: hootController)
        self.hootController = hootController
        self.explainerPanelManager = explainerPanelManager
        self.petOverlayManager = petOverlayManager

        hootController.start()
        menuBarController = MenuBarController(hootController: hootController)

        // Clicking the dozing corner hoot opens the panel too.
        petOverlayManager.onCornerPetClicked = { [weak self] in
            self?.menuBarController?.togglePanel()
        }

        wireExplainerPanel(hootController: hootController, explainerPanelManager: explainerPanelManager)
        wireMemory(hootController: hootController, explainerPanelManager: explainerPanelManager)
        showPetOverlaysOncePermissionsAreGranted(hootController: hootController)

        // Let the first permission poll land before deciding whether the
        // onboarding panel needs to open by itself.
        hootController.permissionCenter.refreshNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.menuBarController?.showPanelIfAnyPermissionIsMissing()
        }

        triggerDebugExplainerRequestIfRequested(hootController: hootController)
    }

    /// Opening hoot again (Finder, Spotlight, the Dock) shows the panel — a way
    /// in even when the menu bar is too crowded to show hoot's icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hootController?.stop()
    }

    // MARK: - Wiring

    private func wireExplainerPanel(hootController: HootController, explainerPanelManager: ExplainerPanelManager) {
        hootController.$latestExplainerVideoRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak explainerPanelManager] explainerVideoRequest in
                explainerPanelManager?.showAndGenerate(request: explainerVideoRequest)
            }
            .store(in: &cancellables)

        // The panel has its own pet perched on it in every phase (the
        // buddies play catch while it renders), and it sits in the corner
        // where hoot dozes and nudges appear, so the overlay pet steps aside
        // and nudges wait for as long as the panel is open at all. Keying
        // this off "showing a picture" let a review nudge and the corner
        // hoot pile onto the panel while a sketch was still rendering.
        explainerPanelManager.$isExplainerPanelOpen
            .removeDuplicates()
            .sink { [weak hootController] isExplainerPanelOpen in
                hootController?.isExplainerPanelOpen = isExplainerPanelOpen
            }
            .store(in: &cancellables)

        explainerPanelManager.onExplainerPanelClosed = { [weak hootController] in
            guard let hootController else { return }
            hootController.isExplainerPanelOpen = false
            Task { await hootController.youTubeContextProvider.resumeVideoIfWePausedIt() }
        }
    }

    /// Memory: finished explainer videos are saved with the question that
    /// asked for them, spaced review starts checking for due concepts, and
    /// the nudge triggers that live outside the memory core are installed.
    private func wireMemory(hootController: HootController, explainerPanelManager: ExplainerPanelManager) {
        // The panel runs one studio job at a time and a new request replaces
        // the old one, so a finished video belongs to the most recent
        // question that asked for one.
        explainerPanelManager.onFinishedVideoReady = { [weak hootController] finishedVideoURL in
            guard let memoryEntryId = hootController?.memoryEntryIdForMostRecentExplainerVideoRequest else { return }
            MemoryStore.shared.attachExplainerVideo(url: finishedVideoURL, toEntryWithId: memoryEntryId)
        }

        // A forgotten review whose concept has a saved animation: offer it.
        // The review nudge was just on screen, so the rate limit would block
        // this one; wait for it (a couple of minutes at most).
        hootController.onReviewForgotWithSavedVideo = { [weak explainerPanelManager] memoryEntry in
            guard let savedVideoURL = memoryEntry.explainerVideoURL else { return }
            NudgeCenter.shared.postNudgeWhenAllowed(HootNudge(
                kind: .reviewDue,
                message: "want the \(memoryEntry.concept) animation again?",
                emphasizedPhrase: memoryEntry.concept,
                primaryButtonTitle: "play",
                primaryAction: {
                    explainerPanelManager?.playSavedVideo(url: savedVideoURL, title: memoryEntry.question)
                },
                secondaryButtonTitle: "no thanks"
            ), givingUpAfterSeconds: 180)
        }

        SpacedReviewScheduler.shared.start(hootController: hootController)
        NudgeTriggers.install(hootController: hootController, explainerPanelManager: explainerPanelManager)
    }

    /// The overlay needs screen recording + accessibility to be useful, so it
    /// appears once everything is granted (the overlay itself decides between
    /// the corner pet and staying hidden). Screen changes rebuild it.
    private func showPetOverlaysOncePermissionsAreGranted(hootController: HootController) {
        hootController.permissionCenter.objectWillChange
            // objectWillChange fires before the new value lands; read it next turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak hootController] _ in
                guard let self, let hootController, !self.hasShownPetOverlays,
                      hootController.permissionCenter.allPermissionsGranted else { return }
                self.hasShownPetOverlays = true
                self.petOverlayManager?.showOverlays()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.hasShownPetOverlays else { return }
                self.petOverlayManager?.showOverlays()
            }
            .store(in: &cancellables)
    }

    /// EXPLAINER_DEBUG_BRIEF="..." (and optionally EXPLAINER_DEBUG_QUESTION)
    /// fires an explainer request shortly after launch, for testing the
    /// studio and panel without talking to hoot.
    private func triggerDebugExplainerRequestIfRequested(hootController: HootController) {
        let environment = ProcessInfo.processInfo.environment
        guard let debugBrief = environment["EXPLAINER_DEBUG_BRIEF"], !debugBrief.isEmpty else { return }
        let debugQuestion = environment["EXPLAINER_DEBUG_QUESTION"] ?? "can you show me how this works?"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak hootController] in
            hootController?.latestExplainerVideoRequest = HootController.ExplainerVideoRequest(
                question: debugQuestion,
                brief: debugBrief,
                spokenAnswer: ""
            )
        }
    }
}
