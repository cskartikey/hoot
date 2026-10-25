//
//  WaitWhatVoiceSettings.swift
//  Hoot
//
//  The tutor's voice provider, voice and speaking speed, picked in the menu
//  bar panel's settings and persisted to UserDefaults. CartesiaTTSClient
//  sends them with every /tts request; the worker forwards them to Cartesia
//  (voice id + `generation_config.speed`) or, when the learner switched to
//  ElevenLabs, to ElevenLabs (voice id + `voice_settings.speed`).
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

/// Who speaks. Cartesia is the default live voice; ElevenLabs is the
/// switchable alternative. Both come back from the worker as the same mp3,
/// so only the /tts request body changes.
enum WaitWhatVoiceProvider: String, CaseIterable, Identifiable {
    case cartesia
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cartesia: return "cartesia"
        case .elevenLabs: return "elevenlabs"
        }
    }

    /// The `provider` value the worker's /tts and /tts/voices routes expect.
    var workerRequestValue: String {
        switch self {
        case .cartesia: return "cartesia"
        case .elevenLabs: return "elevenlabs"
        }
    }
}

/// One ElevenLabs voice, as the worker's GET /tts/voices lists it.
nonisolated struct WaitWhatElevenLabsVoice: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
}

nonisolated private struct WaitWhatElevenLabsVoiceListResponse: Decodable {
    let voices: [WaitWhatElevenLabsVoice]
}

@MainActor
final class WaitWhatVoiceSettingsStore: ObservableObject {
    static let shared = WaitWhatVoiceSettingsStore()

    /// The worker's curated ElevenLabs voices, mirrored here so the picker
    /// has something to show before the fetch lands (or when the worker is
    /// down). The fetched list replaces it.
    static let builtInElevenLabsVoices: [WaitWhatElevenLabsVoice] = [
        WaitWhatElevenLabsVoice(id: "Xb7hH8MSUJpSbSDYk0k2", name: "clear educator"),
        WaitWhatElevenLabsVoice(id: "JBFqnCBsd6RMkjVDRZzb", name: "warm storyteller"),
        WaitWhatElevenLabsVoice(id: "XrExE9yKIg1WjnnlVkGX", name: "upbeat professional"),
        WaitWhatElevenLabsVoice(id: "SAz9YHcvj6GT2YYXdXww", name: "relaxed narrator"),
    ]

    /// Cartesia accepts speeds from 0.6 to 1.5 (generation_config.speed).
    static let minimumSpeakingSpeed: Double = 0.6
    static let maximumSpeakingSpeed: Double = 1.5

    private static let selectedVoiceDefaultsKey = "waitWhatSelectedVoice"
    private static let speakingSpeedDefaultsKey = "waitWhatSpeakingSpeed"
    private static let selectedVoiceProviderDefaultsKey = "waitWhatSelectedVoiceProvider"
    private static let selectedElevenLabsVoiceIDDefaultsKey = "waitWhatSelectedElevenLabsVoiceID"

    /// The Cartesia voice. Kept selected even while ElevenLabs is the
    /// provider, so switching back restores it.
    @Published var selectedVoice: WaitWhatVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: Self.selectedVoiceDefaultsKey)
        }
    }

    @Published var selectedVoiceProvider: WaitWhatVoiceProvider {
        didSet {
            UserDefaults.standard.set(selectedVoiceProvider.rawValue, forKey: Self.selectedVoiceProviderDefaultsKey)
            if selectedVoiceProvider == .elevenLabs {
                loadElevenLabsVoicesIfNeeded()
            }
        }
    }

    /// The ElevenLabs voice id. Resolved against `elevenLabsVoices` by
    /// `selectedElevenLabsVoice`, which falls back to the first voice.
    @Published var selectedElevenLabsVoiceID: String {
        didSet {
            UserDefaults.standard.set(selectedElevenLabsVoiceID, forKey: Self.selectedElevenLabsVoiceIDDefaultsKey)
        }
    }

    /// The ElevenLabs voices offered in the picker: the built-in mirror until
    /// the worker's list arrives.
    @Published private(set) var elevenLabsVoices: [WaitWhatElevenLabsVoice] = WaitWhatVoiceSettingsStore.builtInElevenLabsVoices
    private var elevenLabsVoiceListFetchTask: Task<Void, Never>?
    private var hasFetchedElevenLabsVoices = false

    var selectedElevenLabsVoice: WaitWhatElevenLabsVoice {
        elevenLabsVoices.first { $0.id == selectedElevenLabsVoiceID }
            ?? elevenLabsVoices.first
            ?? Self.builtInElevenLabsVoices[0]
    }

    /// What the voice field in settings shows for the current provider.
    var selectedVoiceDisplayName: String {
        switch selectedVoiceProvider {
        case .cartesia: return selectedVoice.displayName
        case .elevenLabs: return selectedElevenLabsVoice.name
        }
    }

    /// The `voice_id` to send with a /tts request for the current provider.
    var selectedVoiceIDForTTSRequest: String {
        switch selectedVoiceProvider {
        case .cartesia: return selectedVoice.cartesiaVoiceID
        case .elevenLabs: return selectedElevenLabsVoice.id
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

        self.selectedVoiceProvider = UserDefaults.standard.string(forKey: Self.selectedVoiceProviderDefaultsKey)
            .flatMap(WaitWhatVoiceProvider.init(rawValue:)) ?? .cartesia
        self.selectedElevenLabsVoiceID = UserDefaults.standard.string(forKey: Self.selectedElevenLabsVoiceIDDefaultsKey)
            ?? Self.builtInElevenLabsVoices[0].id

        if selectedVoiceProvider == .elevenLabs {
            loadElevenLabsVoicesIfNeeded()
        }
    }

    /// Asks the worker for its ElevenLabs voice list once per launch. The app
    /// never holds the ElevenLabs key, so the worker owns the list.
    func loadElevenLabsVoicesIfNeeded() {
        guard !hasFetchedElevenLabsVoices, elevenLabsVoiceListFetchTask == nil else { return }
        guard let voiceListURL = URL(string: "\(HootController.workerBaseURL)/tts/voices?provider=elevenlabs") else { return }
        elevenLabsVoiceListFetchTask = Task { [weak self] in
            defer { self?.elevenLabsVoiceListFetchTask = nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: voiceListURL)
                let voiceList = try JSONDecoder().decode(WaitWhatElevenLabsVoiceListResponse.self, from: data)
                guard let self, !voiceList.voices.isEmpty else { return }
                self.elevenLabsVoices = voiceList.voices
                self.hasFetchedElevenLabsVoices = true
            } catch {
                // Keep the built-in mirror; the next picker open retries.
                print("⚠️ Could not load ElevenLabs voices from the worker: \(error.localizedDescription)")
            }
        }
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
