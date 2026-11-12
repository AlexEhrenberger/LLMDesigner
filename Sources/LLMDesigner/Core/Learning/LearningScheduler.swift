import Foundation

/// When a card comes up next. Two algorithms the person can choose: FSRS (version 4.5 with its published default
/// weights; the interval follows the wanted retention) and SM-2 as Anki has it (a factor per card). Both start new
/// cards and forgotten ones with short steps in minutes.
struct LearningScheduler: Sendable {
    let settings: LearningSettings

    static let day: TimeInterval = 86_400

    // MARK: FSRS 4.5

    static let w: [Double] = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367,
                              1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755]
    static let decay = -0.5
    static let factor = 19.0 / 81.0

    /// The chance to remember after `days` with stability `stability`.
    static func retrievability(days: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + factor * max(0, days) / stability, decay)
    }

    /// Days until the chance falls to `retention`.
    static func fsrsInterval(stability: Double, retention: Double) -> Double {
        stability / factor * (pow(retention, 1 / decay) - 1)
    }

    static func initialStability(_ rating: CardRating) -> Double { w[rating.rawValue - 1] }

    static func initialDifficulty(_ rating: CardRating) -> Double {
        clampDifficulty(w[4] - Double(rating.rawValue - 3) * w[5])
    }

    static func clampDifficulty(_ value: Double) -> Double { min(10, max(1, value)) }

    static func nextDifficulty(_ difficulty: Double, _ rating: CardRating) -> Double {
        let shifted = difficulty - w[6] * Double(rating.rawValue - 3)
        // Mean reversion towards the difficulty of a "Gut" on a new card.
        return clampDifficulty(w[7] * initialDifficulty(.good) + (1 - w[7]) * shifted)
    }

    static func recallStability(difficulty: Double, stability: Double, retrievability: Double, rating: CardRating) -> Double {
        let hard = rating == .hard ? w[15] : 1
        let easy = rating == .easy ? w[16] : 1
        return stability * (exp(w[8]) * (11 - difficulty) * pow(stability, -w[9]) * (exp(w[10] * (1 - retrievability)) - 1) * hard * easy + 1)
    }

    static func forgetStability(difficulty: Double, stability: Double, retrievability: Double) -> Double {
        let value = w[11] * pow(difficulty, -w[12]) * (pow(stability + 1, w[13]) - 1) * exp(w[14] * (1 - retrievability))
        // Forgetting never makes a card more stable than it was.
        return min(value, stability)
    }

    // MARK: Answering

    /// The card after an answer at `now`.
    func answer(_ card: LearningCard, _ rating: CardRating, at now: Date = Date()) -> LearningCard {
        var next = card
        let before = card.state
        switch settings.algorithm {
        case .fsrs: fsrs(&next, rating, now)
        case .sm2: sm2(&next, rating, now)
        }
        next.reps += 1
        next.lastReview = now
        next.history.append(CardReview(date: now, rating: rating, state: before, interval: next.due.timeIntervalSince(now) / Self.day))
        return next
    }

    /// What each answer would give, as a duration („10 Min.“, „3 T.“), for the buttons.
    func preview(_ card: LearningCard, at now: Date = Date()) -> [CardRating: TimeInterval] {
        var result: [CardRating: TimeInterval] = [:]
        for rating in CardRating.allCases {
            result[rating] = answer(card, rating, at: now).due.timeIntervalSince(now)
        }
        return result
    }

    private func minutes(_ value: Double) -> TimeInterval { value * 60 }

    private func capped(_ days: Double) -> Double {
        min(settings.maxInterval, max(1, days.rounded()))
    }

    /// The steps a new or forgotten card goes through; true when it graduates with this answer.
    private func step(_ card: inout LearningCard, _ rating: CardRating, steps: [Double], now: Date) -> Bool {
        let steps = steps.isEmpty ? [10] : steps
        switch rating {
        case .again:
            card.step = 0
            card.due = now.addingTimeInterval(minutes(steps[0]))
            return false
        case .hard:
            // Halfway between this step and the next, or the same step again.
            let current = steps[min(card.step, steps.count - 1)]
            let next = card.step + 1 < steps.count ? steps[card.step + 1] : current * 1.5
            card.due = now.addingTimeInterval(minutes((current + next) / 2))
            return false
        case .good:
            if card.step + 1 < steps.count {
                card.step += 1
                card.due = now.addingTimeInterval(minutes(steps[card.step]))
                return false
            }
            return true
        case .easy:
            return true
        }
    }

    private func fsrs(_ card: inout LearningCard, _ rating: CardRating, _ now: Date) {
        let elapsed = card.lastReview.map { now.timeIntervalSince($0) / Self.day } ?? 0
        switch card.state {
        case .new:
            card.stability = Self.initialStability(rating)
            card.difficulty = Self.initialDifficulty(rating)
            card.state = .learning
            card.step = 0
            if step(&card, rating, steps: settings.learningSteps, now: now) { graduate(&card, now) }
        case .learning, .relearning:
            // Short-term answers move stability and difficulty a little, as in a review the same day.
            let r = Self.retrievability(days: elapsed, stability: card.stability)
            card.difficulty = Self.nextDifficulty(card.difficulty, rating)
            if rating != .again {
                card.stability = max(card.stability, Self.recallStability(difficulty: card.difficulty, stability: card.stability, retrievability: r, rating: rating))
            }
            if step(&card, rating, steps: card.state == .learning ? settings.learningSteps : settings.relearningSteps, now: now) { graduate(&card, now) }
        case .review:
            let r = Self.retrievability(days: elapsed, stability: card.stability)
            card.difficulty = Self.nextDifficulty(card.difficulty, rating)
            if rating == .again {
                card.stability = Self.forgetStability(difficulty: card.difficulty, stability: card.stability, retrievability: r)
                card.lapses += 1
                card.state = .relearning
                card.step = 0
                if settings.relearningSteps.isEmpty {
                    graduate(&card, now)
                } else {
                    card.due = now.addingTimeInterval(minutes(settings.relearningSteps[0]))
                }
            } else {
                card.stability = Self.recallStability(difficulty: card.difficulty, stability: card.stability, retrievability: r, rating: rating)
                var days = capped(Self.fsrsInterval(stability: card.stability, retention: settings.retention))
                // "Leicht" waits at least a day longer than last time ("Schwer" is shorter through its weight).
                if rating == .easy { days = max(days, card.interval + 1) }
                card.interval = days
                card.due = now.addingTimeInterval(days * Self.day)
            }
        }
    }

    private func graduate(_ card: inout LearningCard, _ now: Date) {
        let days: Double
        switch settings.algorithm {
        case .fsrs:
            days = capped(Self.fsrsInterval(stability: max(card.stability, 0.1), retention: settings.retention))
        case .sm2:
            days = 1
        }
        card.state = .review
        card.step = 0
        card.interval = days
        card.due = now.addingTimeInterval(days * Self.day)
    }

    private func sm2(_ card: inout LearningCard, _ rating: CardRating, _ now: Date) {
        switch card.state {
        case .new, .learning, .relearning:
            if card.state == .new {
                card.ease = settings.startingEase
                card.state = .learning
                card.step = 0
            }
            let relearning = card.state == .relearning
            let graduates = step(&card, rating, steps: relearning ? settings.relearningSteps : settings.learningSteps, now: now)
            guard graduates else { return }
            let days: Double = relearning ? 1 : (rating == .easy ? 4 : 1)
            card.state = .review
            card.step = 0
            card.interval = capped(days * settings.intervalModifier)
            card.due = now.addingTimeInterval(card.interval * Self.day)
        case .review:
            let late = max(0, now.timeIntervalSince(card.due) / Self.day)
            switch rating {
            case .again:
                card.lapses += 1
                card.ease = max(1.3, card.ease - 0.2)
                card.state = .relearning
                card.step = 0
                card.interval = 1
                card.due = now.addingTimeInterval(minutes(settings.relearningSteps.first ?? 10))
                return
            case .hard:
                card.ease = max(1.3, card.ease - 0.15)
                card.interval = capped(max(card.interval + 1, card.interval * 1.2) * settings.intervalModifier)
            case .good:
                card.interval = capped(max(card.interval + 1, (card.interval + late / 2) * card.ease) * settings.intervalModifier)
            case .easy:
                card.ease += 0.15
                card.interval = capped(max(card.interval + 1, (card.interval + late) * card.ease * settings.easyBonus) * settings.intervalModifier)
            }
            card.due = now.addingTimeInterval(card.interval * Self.day)
        }
    }

    /// „1 Min.“, „10 Min.“, „3 Std.“, „4 T.“, „2,5 Mon.“, „1,2 J.“
    static func label(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, Int(minutes.rounded()))) Min." }
        let hours = minutes / 60
        if hours < 22 { return "\(Int(hours.rounded())) Std." }
        let days = hours / 24
        if days < 31 { return "\(Int(days.rounded())) T." }
        let german = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE"))
        if days < 365 { return (days / 30.4).formatted(german) + " Mon." }
        return (days / 365).formatted(german) + " J."
    }
}
