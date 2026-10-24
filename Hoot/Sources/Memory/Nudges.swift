//
//  Nudges.swift
//  Hoot
//
//  SKELETON — owned by the nudge agent (may split into more files). Corner
//  nudges beside the dozing hoot (docs/MEMORY.md §9). The memory core
//  agent posts review nudges through NudgeCenter; keep names/signatures.
//

import Combine
import Foundation

// MARK: - Nudges

/// A small bubble beside the corner hoot with up to two buttons.
struct HootNudge: Identifiable {
    enum Kind: String {
        case reviewDue
        case videoReadyWhileAway
        case sameIdeaAsBefore
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// Words in `message` to emphasize (e.g. the concept or video title).
    var emphasizedPhrase: String? = nil
    let primaryButtonTitle: String
    let primaryAction: () -> Void
    let secondaryButtonTitle: String
    var secondaryAction: () -> Void = {}
}

@MainActor
final class NudgeCenter: ObservableObject {
    static let shared = NudgeCenter()

    /// The nudge on screen right now, if any.
    @Published private(set) var currentNudge: HootNudge?
    /// Settings toggle; persisted.
    @Published var areNudgesEnabled = true

    /// Shows the nudge if the etiquette rules allow it (rate limit, not
    /// typing, not fullscreen, not while hoot is answering). Returns whether
    /// it was shown.
    @discardableResult
    func postNudgeIfAllowed(_ nudge: HootNudge) -> Bool { false }

    func dismissCurrentNudge(wasIgnored: Bool) {}
}

/// Installs the nudge triggers that live outside the memory core
/// (video ready while away, same idea as before). Called once by the app
/// delegate after launch.
@MainActor
enum NudgeTriggers {
    static func install(hootController: HootController, explainerPanelManager: ExplainerPanelManager) {}
}
