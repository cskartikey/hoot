//
//  WaitWhatVoiceSettings.swift
//  Hoot
//
//  The tutor's voice and speaking speed, picked in the menu bar panel's
//  settings and persisted to UserDefaults. CartesiaTTSClient sends both
//  with every /tts request; the worker forwards them to Cartesia as the
//  voice id and `generation_config.speed`.
//

import Combine
import Foundation

/// A Cartesia voice offered in settings, with a friendly lowercase name.
enum WaitWhatVoice: String, CaseIterable, Identifiable {
    case warmProfessor
    case calmExplainer
    case brightGuide
    case britishStoryteller

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .warmProfessor: return "warm professor"
        case .calmExplainer: return "calm explainer"
        case .brightGuide: return "bright guide"
        case .britishStoryteller: return "british storyteller"
        }
    }

    var cartesiaVoiceID: String {
        switch self {
        case .warmProfessor: return "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4" // Skylar
        case .calmExplainer: return "47c38ca4-5f35-497b-b1a3-415245fb35e1" // Daniel
        case .brightGuide: return "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc" // Jacqueline
        case .britishStoryteller: return "ef191366-f52f-447a-a398-ed8c0f2943a1" // Archie
        }
    }
}

@MainActor
final class WaitWhatVoiceSettingsStore: ObservableObject {
    static let shared = WaitWhatVoiceSettingsStore()

    /// Cartesia accepts speeds from 0.6 to 1.5 (generation_config.speed).
    static let minimumSpeakingSpeed: Double = 0.6
    static let maximumSpeakingSpeed: Double = 1.5

    private static let selectedVoiceDefaultsKey = "waitWhatSelectedVoice"
    private static let speakingSpeedDefaultsKey = "waitWhatSpeakingSpeed"

    @Published var selectedVoice: WaitWhatVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: Self.selectedVoiceDefaultsKey)
        }
    }

    @Published var speakingSpeed: Double {
        didSet {
            UserDefaults.standard.set(speakingSpeed, forKey: Self.speakingSpeedDefaultsKey)
        }
    }

    private init() {
        self.selectedVoice = UserDefaults.standard.string(forKey: Self.selectedVoiceDefaultsKey)
            .flatMap(WaitWhatVoice.init(rawValue:)) ?? .warmProfessor

        let storedSpeakingSpeed = UserDefaults.standard.object(forKey: Self.speakingSpeedDefaultsKey) as? Double
        self.speakingSpeed = storedSpeakingSpeed ?? 1.0
    }

    /// A separate TTS client for the settings preview button, so previewing a
    /// voice never interrupts (or gets interrupted by) the tutor's own speech.
    private lazy var voicePreviewTTSClient = CartesiaTTSClient(proxyURL: "\(HootController.workerBaseURL)/tts")
    private var voicePreviewTask: Task<Void, Never>?

    /// Speaks a short line in the selected voice and speed.
    func playVoicePreview(petName: String) {
        voicePreviewTask?.cancel()
        voicePreviewTTSClient.stopPlayback()
        let voicePreviewText = "hey, i'm \(petName). hold control and option, and ask me anything on your screen."
        voicePreviewTask = Task { [voicePreviewTTSClient] in
            do {
                try await voicePreviewTTSClient.speakText(voicePreviewText)
            } catch {
                print("⚠️ Voice preview failed: \(error.localizedDescription)")
            }
        }
    }
}
