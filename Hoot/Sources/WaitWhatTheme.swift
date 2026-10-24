//
//  WaitWhatTheme.swift
//  Hoot
//
//  The "wait, what?" crisp theme from the Claude Design handoff
//  (design_handoff_wait_what/README.md). One layout, themed on two
//  independent axes:
//    - appearance (system / light / dark) swaps the neutral tokens only
//    - mascot (hoot / lotl / bit) swaps the pet sprite, its name in copy,
//      and the two accent colors
//  Also holds the bundled JetBrains Mono fonts, the pet sprite loader, and
//  small shared pieces (glass panel background, keycap, pet sprite view)
//  so every surface draws them the same way.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Theme axes

enum WaitWhatAppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark
}

enum WaitWhatMascot: String, CaseIterable, Identifiable {
    case hoot
    case lotl
    case bit

    var id: String { rawValue }

    /// The name used in copy ("hoot is ready", "hey, i'm hoot.").
    var displayName: String { rawValue }

    /// File name (without extension) of this mascot's sprites in Pets/.
    var spriteResourceName: String { rawValue }

    /// The small head-only sprite that rides at the cursor while answering.
    /// Only hoot has one; other mascots use their full body drawn small.
    var cursorHeadSpriteResourceName: String? {
        self == .hoot ? "hoot-head" : nil
    }
}

/// Which drawing of the mascot to use: the full 24×24 body (corner home,
/// panels) or the 12×12 head that follows the cursor when asked.
enum PetSpriteVariant {
    case fullBody
    case cursorHead
}

// MARK: - Resolved theme

/// Every color a surface needs, already resolved for the current
/// appearance and mascot. Views read this instead of hardcoding colors.
struct WaitWhatTheme {
    let isDark: Bool
    let mascot: WaitWhatMascot

    // Neutrals (appearance axis)
    let pageBackground: Color
    let ink: Color
    let ink2: Color
    let muted: Color
    let faint: Color
    /// Tint laid over `.ultraThinMaterial` for every panel and bubble.
    let glassTint: Color
    /// Keycaps, the selected buddy tile, the select field.
    let solid: Color
    /// The selected segment in a segmented control.
    let segmentSelected: Color
    /// Base for hairlines and fills: use `foreground(opacity:)`.
    let foregroundBase: Color
    let shadowColor: Color
    let panelShadowOpacity: Double
    let ok: Color
    /// Background of the small status pill on the rendering placeholder.
    let pill: Color
    let placeholderStripeA: Color
    let placeholderStripeB: Color

    // Accents (mascot axis)
    let accent: Color
    let onAccent: Color
    let accent2: Color
    let accent2Ink: Color

    /// Hairlines and fills, e.g. borders at 0.12, separators at 0.08–0.10.
    func foreground(opacity: Double) -> Color {
        foregroundBase.opacity(opacity)
    }

    static func resolve(isDark: Bool, mascot: WaitWhatMascot) -> WaitWhatTheme {
        let accentColors = mascotAccentColors(for: mascot, isDark: isDark)

        if isDark {
            return WaitWhatTheme(
                isDark: true,
                mascot: mascot,
                pageBackground: Color(hex: "#161617"),
                ink: Color(hex: "#F2F2F7"),
                ink2: Color(hex: "#C7C7CC"),
                muted: Color(hex: "#98989D"),
                faint: Color(hex: "#6E6E73"),
                glassTint: Color(red: 40 / 255, green: 40 / 255, blue: 43 / 255).opacity(0.80),
                solid: Color(hex: "#3A3A3C"),
                segmentSelected: Color(hex: "#5A5A5E"),
                foregroundBase: .white,
                shadowColor: .black,
                panelShadowOpacity: 0.55,
                ok: Color(hex: "#30D158"),
                pill: Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255).opacity(0.92),
                placeholderStripeA: Color(hex: "#2A2B2E"),
                placeholderStripeB: Color(hex: "#2E2F32"),
                accent: accentColors.accent,
                onAccent: accentColors.onAccent,
                accent2: accentColors.accent2,
                accent2Ink: accentColors.accent2Ink
            )
        }

        return WaitWhatTheme(
            isDark: false,
            mascot: mascot,
            pageBackground: Color(hex: "#DDE2E7"),
            ink: Color(hex: "#1C1C1E"),
            ink2: Color(hex: "#3A3A3C"),
            muted: Color(hex: "#6C6C70"),
            faint: Color(hex: "#8E8E93"),
            glassTint: Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.82),
            solid: .white,
            segmentSelected: .white,
            foregroundBase: .black,
            shadowColor: Color(red: 20 / 255, green: 30 / 255, blue: 40 / 255),
            panelShadowOpacity: 0.30,
            ok: Color(hex: "#34C759"),
            pill: Color.white.opacity(0.9),
            placeholderStripeA: Color(hex: "#E8EBEE"),
            placeholderStripeB: Color(hex: "#EEF1F3"),
            accent: accentColors.accent,
            onAccent: accentColors.onAccent,
            accent2: accentColors.accent2,
            accent2Ink: accentColors.accent2Ink
        )
    }

    private static func mascotAccentColors(
        for mascot: WaitWhatMascot,
        isDark: Bool
    ) -> (accent: Color, onAccent: Color, accent2: Color, accent2Ink: Color) {
        switch mascot {
        case .hoot:
            // "ember + blue"
            return (Color(hex: "#E5673A"), .white, Color(hex: "#3F7FE0"),
                    Color(hex: isDark ? "#8DB6F5" : "#2A5FB0"))
        case .lotl:
            return (Color(hex: "#E0606E"), .white, Color(hex: "#1FA6B8"),
                    Color(hex: isDark ? "#6FD3E0" : "#137886"))
        case .bit:
            return (Color(hex: "#22B35E"), Color(hex: "#04140A"), Color(hex: "#D9982B"),
                    Color(hex: isDark ? "#F2C46E" : "#8A5E12"))
        }
    }
}

// MARK: - Theme store

/// Persists the two theme axes and publishes the resolved theme so every
/// view re-renders when the mascot, the appearance setting, or the system
/// appearance changes.
@MainActor
final class WaitWhatThemeStore: ObservableObject {
    static let shared = WaitWhatThemeStore()

    private static let appearanceSettingDefaultsKey = "waitWhatAppearanceSetting"
    private static let mascotDefaultsKey = "waitWhatMascot"

    @Published var appearanceSetting: WaitWhatAppearanceSetting {
        didSet {
            UserDefaults.standard.set(appearanceSetting.rawValue, forKey: Self.appearanceSettingDefaultsKey)
            refreshResolvedTheme()
        }
    }

    @Published var mascot: WaitWhatMascot {
        didSet {
            UserDefaults.standard.set(mascot.rawValue, forKey: Self.mascotDefaultsKey)
            refreshResolvedTheme()
        }
    }

    @Published private(set) var theme: WaitWhatTheme

    private var systemAppearanceObservation: NSKeyValueObservation?

    private init() {
        let storedAppearanceSetting = UserDefaults.standard.string(forKey: Self.appearanceSettingDefaultsKey)
            .flatMap(WaitWhatAppearanceSetting.init(rawValue:)) ?? .system
        let storedMascot = UserDefaults.standard.string(forKey: Self.mascotDefaultsKey)
            .flatMap(WaitWhatMascot.init(rawValue:)) ?? .hoot

        self.appearanceSetting = storedAppearanceSetting
        self.mascot = storedMascot
        self.theme = WaitWhatTheme.resolve(
            isDark: Self.isDark(for: storedAppearanceSetting),
            mascot: storedMascot
        )

        // Follow the system light/dark switch live when the setting is .system.
        systemAppearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshResolvedTheme()
            }
        }
    }

    /// The NSAppearance AppKit windows should use so system materials
    /// (`.ultraThinMaterial`) match the theme.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    private func refreshResolvedTheme() {
        theme = WaitWhatTheme.resolve(isDark: Self.isDark(for: appearanceSetting), mascot: mascot)
    }

    private static func isDark(for appearanceSetting: WaitWhatAppearanceSetting) -> Bool {
        switch appearanceSetting {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            let systemAppearanceName = NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua])
            return systemAppearanceName == .darkAqua
        }
    }
}

// MARK: - Fonts

enum WaitWhatFonts {
    /// Registers the bundled JetBrains Mono TTFs with the process so
    /// `Font.custom` can find them. Call once at launch.
    static func registerBundledFonts() {
        var bundledFontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        bundledFontURLs += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []

        for bundledFontURL in bundledFontURLs where bundledFontURL.lastPathComponent.hasPrefix("JetBrainsMono") {
            var registrationError: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(bundledFontURL as CFURL, .process, &registrationError) {
                // Already registered is fine; anything else is worth a log line.
                print("⚠️ Font registration failed for \(bundledFontURL.lastPathComponent)")
            }
        }
    }
}

extension Font {
    /// JetBrains Mono for UI labels, meta text, keycaps and buttons.
    /// Weights in the design: .regular (400), .medium (500), .semibold (600).
    static func jetBrainsMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let postScriptName: String
        switch weight {
        case .semibold, .bold, .heavy, .black:
            postScriptName = "JetBrainsMono-SemiBold"
        case .medium:
            postScriptName = "JetBrainsMono-Medium"
        default:
            postScriptName = "JetBrainsMono-Regular"
        }
        return .custom(postScriptName, size: size)
    }
}

// MARK: - Pet sprites

/// The animation states every mascot has (see the handoff's pet section).
enum PetAnimationState: String, CaseIterable {
    case idle
    case listening
    case thinking
    case talking
    case pointing
    case presenting
    case hello
    // Walkthrough head states (WALKTHROUGH.md): watching the learner work,
    // watching with the cursor inside the box, the peek, and the done hop.
    case watching
    case watchingIn
    case peek
    case happy
}

/// One mascot's frames, decoded from Pets/<name>.json
/// (schema: size, palette char → #RRGGBBAA, animations.<state>[] = {rows, ms}).
struct PetSpriteSheet {
    struct Frame {
        /// One string per pixel row; "." is transparent, other characters index the palette.
        let rows: [String]
        let durationInMilliseconds: Int
    }

    let gridSize: Int
    let paletteColorsByCharacter: [Character: Color]
    let paletteNSColorsByCharacter: [Character: NSColor]
    let framesByState: [PetAnimationState: [Frame]]

    func frames(for state: PetAnimationState) -> [Frame] {
        framesByState[state] ?? framesByState[.idle] ?? []
    }

    /// The frame to show at `date`, cycling through the state's frames by their durations.
    func frame(for state: PetAnimationState, at date: Date) -> Frame? {
        let stateFrames = frames(for: state)
        guard !stateFrames.isEmpty else { return nil }
        let cycleDurationInMilliseconds = stateFrames.reduce(0) { $0 + $1.durationInMilliseconds }
        guard cycleDurationInMilliseconds > 0 else { return stateFrames.first }

        let elapsedMilliseconds = Int(date.timeIntervalSinceReferenceDate * 1000) % cycleDurationInMilliseconds
        var accumulatedMilliseconds = 0
        for stateFrame in stateFrames {
            accumulatedMilliseconds += stateFrame.durationInMilliseconds
            if elapsedMilliseconds < accumulatedMilliseconds {
                return stateFrame
            }
        }
        return stateFrames.last
    }
}

@MainActor
enum PetSpriteLibrary {
    private static var cachedSpriteSheetsByResourceName: [String: PetSpriteSheet] = [:]

    private struct SpriteFileContents: Decodable {
        struct FrameContents: Decodable {
            let rows: [String]
            let ms: Int
        }
        let size: Int
        let palette: [String: String]
        let animations: [String: [FrameContents]]
    }

    static func spriteSheet(for mascot: WaitWhatMascot, variant: PetSpriteVariant = .fullBody) -> PetSpriteSheet? {
        if variant == .cursorHead, let cursorHeadSpriteResourceName = mascot.cursorHeadSpriteResourceName {
            return spriteSheet(resourceName: cursorHeadSpriteResourceName)
        }
        return spriteSheet(resourceName: mascot.spriteResourceName)
    }

    static func spriteSheet(resourceName spriteResourceName: String) -> PetSpriteSheet? {
        if let cachedSpriteSheet = cachedSpriteSheetsByResourceName[spriteResourceName] {
            return cachedSpriteSheet
        }

        let spriteFileURL = Bundle.main.url(forResource: spriteResourceName, withExtension: "json")
            ?? Bundle.main.url(forResource: spriteResourceName, withExtension: "json", subdirectory: "Pets")
        guard let spriteFileURL,
              let spriteFileData = try? Data(contentsOf: spriteFileURL),
              let spriteFileContents = try? JSONDecoder().decode(SpriteFileContents.self, from: spriteFileData) else {
            print("⚠️ Pet sprites missing for \(spriteResourceName)")
            return nil
        }

        var paletteColorsByCharacter: [Character: Color] = [:]
        var paletteNSColorsByCharacter: [Character: NSColor] = [:]
        for (paletteKey, hexColorWithAlpha) in spriteFileContents.palette {
            guard let paletteCharacter = paletteKey.first else { continue }
            let paletteNSColor = nsColor(fromHexWithAlpha: hexColorWithAlpha)
            paletteNSColorsByCharacter[paletteCharacter] = paletteNSColor
            paletteColorsByCharacter[paletteCharacter] = Color(nsColor: paletteNSColor)
        }

        var framesByState: [PetAnimationState: [PetSpriteSheet.Frame]] = [:]
        for (stateName, frameContentsList) in spriteFileContents.animations {
            guard let animationState = PetAnimationState(rawValue: stateName) else { continue }
            framesByState[animationState] = frameContentsList.map {
                PetSpriteSheet.Frame(rows: $0.rows, durationInMilliseconds: $0.ms)
            }
        }

        let spriteSheet = PetSpriteSheet(
            gridSize: spriteFileContents.size,
            paletteColorsByCharacter: paletteColorsByCharacter,
            paletteNSColorsByCharacter: paletteNSColorsByCharacter,
            framesByState: framesByState
        )
        cachedSpriteSheetsByResourceName[spriteResourceName] = spriteSheet
        return spriteSheet
    }

    /// Renders one frame to an NSImage (crisp, nearest-neighbour), for the
    /// menu bar template icon and the app icon. With `silhouetteColor`, every
    /// opaque pixel except the ground shadow and eye whites is drawn in that
    /// color, which is what a menu bar template image needs.
    static func renderImage(
        for mascot: WaitWhatMascot,
        state: PetAnimationState = .idle,
        frameIndex: Int = 0,
        pointsPerPixel: CGFloat,
        silhouetteColor: NSColor? = nil
    ) -> NSImage? {
        guard let spriteSheet = spriteSheet(for: mascot) else { return nil }
        let stateFrames = spriteSheet.frames(for: state)
        guard !stateFrames.isEmpty else { return nil }
        let frame = stateFrames[min(max(frameIndex, 0), stateFrames.count - 1)]

        let imageSideInPoints = CGFloat(spriteSheet.gridSize) * pointsPerPixel
        let renderedImage = NSImage(size: NSSize(width: imageSideInPoints, height: imageSideInPoints), flipped: true) { _ in
            for (rowIndex, rowCharacters) in frame.rows.enumerated() {
                for (columnIndex, pixelCharacter) in rowCharacters.enumerated() {
                    if pixelCharacter == "." { continue }
                    let fillColor: NSColor
                    if let silhouetteColor {
                        // Shadow and eye whites stay transparent so the silhouette reads at 18pt.
                        if pixelCharacter == "S" || pixelCharacter == "s" || pixelCharacter == "w" { continue }
                        fillColor = silhouetteColor
                    } else {
                        guard let paletteColor = spriteSheet.paletteNSColorsByCharacter[pixelCharacter] else { continue }
                        fillColor = paletteColor
                    }
                    fillColor.setFill()
                    NSRect(
                        x: CGFloat(columnIndex) * pointsPerPixel,
                        y: CGFloat(rowIndex) * pointsPerPixel,
                        width: pointsPerPixel,
                        height: pointsPerPixel
                    ).fill()
                }
            }
            return true
        }
        return renderedImage
    }

    private static func nsColor(fromHexWithAlpha hexColorWithAlpha: String) -> NSColor {
        let hexDigits = hexColorWithAlpha.replacingOccurrences(of: "#", with: "")
        var packedValue: UInt64 = 0
        Scanner(string: hexDigits).scanHexInt64(&packedValue)
        let hasAlphaComponent = hexDigits.count == 8
        let red = CGFloat((packedValue >> (hasAlphaComponent ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((packedValue >> (hasAlphaComponent ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((packedValue >> (hasAlphaComponent ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlphaComponent ? CGFloat(packedValue & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Draws the current mascot (or a given one) in a state, animated, as crisp
/// pixel art. Full body is a 24×24 grid: scale 4 = 96pt, 3 = 72pt, 2 = 48pt
/// (corner home, panel header, buddy tiles). The cursor head is 12×12 at
/// scale 2 = 24pt. A mascot without a head sprite draws its full body at
/// half the scale so it takes the same space.
struct PetSpriteView: View {
    var mascot: WaitWhatMascot? = nil
    var variant: PetSpriteVariant = .fullBody
    let state: PetAnimationState
    var scale: CGFloat = 4
    /// Mirror horizontally so the pointing wing faces a target to the left.
    var isMirrored: Bool = false
    /// Show only the first frame of the state (no animation).
    var isStill: Bool = false

    @ObservedObject private var themeStore = WaitWhatThemeStore.shared

    var body: some View {
        let displayedMascot = mascot ?? themeStore.mascot
        let spriteSheet = PetSpriteLibrary.spriteSheet(for: displayedMascot, variant: variant)
        let usesFullBodyInPlaceOfHead = variant == .cursorHead && displayedMascot.cursorHeadSpriteResourceName == nil
        let pixelScale = usesFullBodyInPlaceOfHead ? scale / 2 : scale
        let sideLength = CGFloat(spriteSheet?.gridSize ?? 24) * pixelScale

        Group {
            if let spriteSheet {
                if isStill {
                    pixelCanvas(spriteSheet: spriteSheet, frame: spriteSheet.frames(for: state).first, pixelScale: pixelScale)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.05)) { timelineContext in
                        pixelCanvas(spriteSheet: spriteSheet, frame: spriteSheet.frame(for: state, at: timelineContext.date), pixelScale: pixelScale)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(width: sideLength, height: sideLength)
        .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
        .accessibilityHidden(true)
    }

    private func pixelCanvas(spriteSheet: PetSpriteSheet, frame: PetSpriteSheet.Frame?, pixelScale: CGFloat) -> some View {
        Canvas { graphicsContext, _ in
            guard let frame else { return }
            for (rowIndex, rowCharacters) in frame.rows.enumerated() {
                for (columnIndex, pixelCharacter) in rowCharacters.enumerated() {
                    guard pixelCharacter != ".",
                          let pixelColor = spriteSheet.paletteColorsByCharacter[pixelCharacter] else { continue }
                    let pixelRect = CGRect(
                        x: CGFloat(columnIndex) * pixelScale,
                        y: CGFloat(rowIndex) * pixelScale,
                        width: pixelScale,
                        height: pixelScale
                    )
                    graphicsContext.fill(Path(pixelRect), with: .color(pixelColor))
                }
            }
        }
    }
}

// MARK: - Shared pieces

extension View {
    /// The glass card every panel and bubble uses: material + theme tint,
    /// 0.5pt hairline border, soft panel shadow. Radius 16 for panels,
    /// 14 for the listening bubble.
    func waitWhatGlassPanel(theme: WaitWhatTheme, cornerRadius: CGFloat = 16) -> some View {
        let roundedShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(
                ZStack {
                    roundedShape.fill(.ultraThinMaterial)
                    roundedShape.fill(theme.glassTint)
                }
            )
            .overlay(roundedShape.strokeBorder(theme.foreground(opacity: 0.12), lineWidth: 0.5))
            .clipShape(roundedShape)
            .shadow(color: theme.shadowColor.opacity(theme.panelShadowOpacity), radius: 24, x: 0, y: 16)
    }
}

/// A keyboard key like ⌃ or ⌥: JetBrains Mono 11/600 on `solid`, hairline
/// border and a 1pt bottom shadow.
struct WaitWhatKeycap: View {
    let symbol: String
    var fontSize: CGFloat = 11
    let theme: WaitWhatTheme

    var body: some View {
        Text(symbol)
            .font(.jetBrainsMono(fontSize, weight: .semibold))
            .foregroundColor(theme.ink)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.solid)
                    .shadow(color: theme.foreground(opacity: 0.12), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.foreground(opacity: 0.15), lineWidth: 0.5)
            )
    }
}
