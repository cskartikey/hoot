//
//  HootDemoLog.swift
//  Hoot
//
//  A log of what hoot heard and said, with wall-clock times and the
//  Cartesia clips saved as files, for cutting the demo video: captions come
//  from the exact sentence text at the exact moment it was spoken, and
//  hoot's voice is mixed in clean instead of picked up by a microphone.
//  Off unless the app is launched with HOOT_DEMO_LOG=1 (Xcode scheme
//  environment) or the UserDefaults bool `hootDemoLog` is set. Writes to
//  ~/Library/Application Support/hoot/demo-log/: events.jsonl + clips/.
//

import Foundation

enum HootDemoLog {
    static let environmentVariable = "HOOT_DEMO_LOG"
    static let defaultsKey = "hootDemoLog"

    static let isEnabled: Bool = {
        let environmentFlag = ProcessInfo.processInfo.environment[environmentVariable]
        let isOn = environmentFlag == "1" || UserDefaults.standard.bool(forKey: defaultsKey)
        if isOn { print("🎬 demo log on: \(demoLogDirectory.path)") }
        return isOn
    }()

    static let demoLogDirectory: URL = {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory.appendingPathComponent("hoot/demo-log", isDirectory: true)
    }()

    private static var clipsDirectory: URL { demoLogDirectory.appendingPathComponent("clips", isDirectory: true) }
    private static var eventsFile: URL { demoLogDirectory.appendingPathComponent("events.jsonl") }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The learner's question, once transcribed.
    static func recordQuestion(_ questionText: String) {
        guard isEnabled else { return }
        appendEvent(["type": "question", "text": questionText])
    }

    /// One spoken sentence, at the moment its clip starts playing. The clip
    /// (mp3 from the worker) is saved next to the log.
    static func recordSpeech(sentenceText: String, audioData: Data, durationSeconds: Double) {
        guard isEnabled else { return }
        let clipName = "\(Int(Date().timeIntervalSince1970 * 1000)).mp3"
        do {
            try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
            try audioData.write(to: clipsDirectory.appendingPathComponent(clipName))
        } catch {
            print("⚠️ demo log: couldn't save clip: \(error.localizedDescription)")
        }
        appendEvent(["type": "speech", "text": sentenceText, "clip": "clips/\(clipName)", "duration": durationSeconds])
    }

    /// Anything else worth a caption cue (a seek, a click, a nudge).
    static func recordEvent(_ eventType: String, _ detail: String) {
        guard isEnabled else { return }
        appendEvent(["type": eventType, "text": detail])
    }

    private static func appendEvent(_ fields: [String: Any]) {
        var event = fields
        event["at"] = timestampFormatter.string(from: Date())
        event["unix"] = Date().timeIntervalSince1970
        guard let lineData = try? JSONSerialization.data(withJSONObject: event),
              var line = String(data: lineData, encoding: .utf8) else { return }
        line += "\n"
        do {
            try FileManager.default.createDirectory(at: demoLogDirectory, withIntermediateDirectories: true)
            if let fileHandle = try? FileHandle(forWritingTo: eventsFile) {
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: Data(line.utf8))
            } else {
                try line.write(to: eventsFile, atomically: true, encoding: .utf8)
            }
        } catch {
            print("⚠️ demo log: couldn't write event: \(error.localizedDescription)")
        }
    }
}
