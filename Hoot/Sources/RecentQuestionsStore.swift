//
//  RecentQuestionsStore.swift
//  Hoot
//
//  The last few questions the user asked, shown in the menu bar panel's
//  `recent` list. Persisted to UserDefaults as JSON so they survive restarts.
//  HootController calls `recordQuestion(...)` once per answered question.
//

import Combine
import Foundation

struct RecentQuestion: Codable, Identifiable, Equatable {
    let id: UUID
    let questionText: String
    /// Where the question was asked, e.g. "3blue1brown", "mdn docs", "safari".
    let sourceDescription: String?
    let askedDate: Date
    /// True when the answer came with an explainer video.
    let hadExplainerVideo: Bool
}

@MainActor
final class RecentQuestionsStore: ObservableObject {
    static let shared = RecentQuestionsStore()

    private static let recentQuestionsDefaultsKey = "waitWhatRecentQuestions"
    private static let maximumRecentQuestionCount = 10

    /// Most recent first.
    @Published private(set) var recentQuestions: [RecentQuestion] = []

    private init() {
        if let storedRecentQuestionsData = UserDefaults.standard.data(forKey: Self.recentQuestionsDefaultsKey),
           let storedRecentQuestions = try? JSONDecoder().decode([RecentQuestion].self, from: storedRecentQuestionsData) {
            recentQuestions = storedRecentQuestions
        }
    }

    /// Adds a question to the top of the recent list (keeps the last 10).
    /// `sourceDescription` is the app or site it was asked about, or nil.
    func recordQuestion(
        questionText: String,
        sourceDescription: String?,
        hadExplainerVideo: Bool,
        askedDate: Date = Date()
    ) {
        let trimmedQuestionText = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestionText.isEmpty else { return }

        let trimmedSourceDescription = sourceDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let newRecentQuestion = RecentQuestion(
            id: UUID(),
            questionText: trimmedQuestionText.lowercased(),
            sourceDescription: (trimmedSourceDescription?.isEmpty ?? true) ? nil : trimmedSourceDescription,
            askedDate: askedDate,
            hadExplainerVideo: hadExplainerVideo
        )

        recentQuestions.insert(newRecentQuestion, at: 0)
        if recentQuestions.count > Self.maximumRecentQuestionCount {
            recentQuestions = Array(recentQuestions.prefix(Self.maximumRecentQuestionCount))
        }
        persistRecentQuestions()
    }

    /// Marks the most recent question as having an explainer video, for when
    /// the video request is detected after the question was recorded.
    func markMostRecentQuestionAsHavingExplainerVideo() {
        guard let mostRecentQuestion = recentQuestions.first, !mostRecentQuestion.hadExplainerVideo else { return }
        recentQuestions[0] = RecentQuestion(
            id: mostRecentQuestion.id,
            questionText: mostRecentQuestion.questionText,
            sourceDescription: mostRecentQuestion.sourceDescription,
            askedDate: mostRecentQuestion.askedDate,
            hadExplainerVideo: true
        )
        persistRecentQuestions()
    }

    private func persistRecentQuestions() {
        guard let encodedRecentQuestions = try? JSONEncoder().encode(recentQuestions) else { return }
        UserDefaults.standard.set(encodedRecentQuestions, forKey: Self.recentQuestionsDefaultsKey)
    }

    /// Short relative time for a row's meta line: "now", "5m", "2h",
    /// "yesterday", then the weekday ("tue") within a week, else "oct 3".
    static func relativeTimeDescription(for askedDate: Date, relativeTo currentDate: Date = Date()) -> String {
        let secondsSinceAsked = currentDate.timeIntervalSince(askedDate)
        let calendar = Calendar.current

        if secondsSinceAsked < 60 {
            return "now"
        }
        if secondsSinceAsked < 60 * 60 {
            return "\(Int(secondsSinceAsked / 60))m"
        }
        if calendar.isDate(askedDate, inSameDayAs: currentDate) {
            return "\(Int(secondsSinceAsked / 3600))h"
        }
        if calendar.isDateInYesterday(askedDate) {
            return "yesterday"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        if secondsSinceAsked < 7 * 24 * 60 * 60 {
            dateFormatter.dateFormat = "EEE"
        } else {
            dateFormatter.dateFormat = "MMM d"
        }
        return dateFormatter.string(from: askedDate).lowercased()
    }
}
