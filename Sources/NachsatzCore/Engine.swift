import Foundation
import FoundationModels
import NaturalLanguage

/// Vorhersage mit Apples Sprachmodell auf dem Gerät. Es verlässt kein Text den Mac.
public actor Engine {
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private var warm: (key: String, session: LanguageModelSession)?

    public init() {}

    public nonisolated static var status: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence ist ausgeschaltet"
        case .unavailable(.deviceNotEligible): return "Dieser Mac unterstützt das Modell nicht"
        case .unavailable(.modelNotReady): return "Das Modell wird noch geladen"
        case .unavailable: return "Das Modell ist nicht verfügbar"
        }
    }

    /// nil, wenn der Text zu kurz oder nicht eindeutig ist.
    public nonisolated static func detect(_ text: String) -> String? {
        guard text.count >= 14 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.german, .english, .french, .spanish, .italian, .dutch, .portuguese]
        r.processString(String(text.suffix(300)))
        guard let best = r.languageHypotheses(withMaximum: 1).first, best.value > 0.55 else { return nil }
        return best.key.rawValue
    }

    public nonisolated static func language(of text: String, fallback: String) -> String { detect(text) ?? fallback }

    public func predict(text: String, language: String, about: String, screen: String = "", maxWords: Int) async throws -> String {
        let key = language + "|" + about + "|" + screen + "|\(maxWords)"
        let session: LanguageModelSession
        if let w = warm, w.key == key { session = w.session } else { session = make(language, about, screen, maxWords) }
        let next = make(language, about, screen, maxWords)
        warm = (key, next)
        defer { next.prewarm() }

        var out = ""
        let stream = session.streamResponse(
            to: String(text.suffix(900)),
            options: Self.options(10 + maxWords * 3))
        for try await part in stream {
            try Task.checkCancellation()
            out = part.content
            let words = out.split(whereSeparator: \.isWhitespace).count
            if words > maxWords + 3 || out.dropFirst(2).contains("\n") { break }
        }
        return out
    }

    /// Der Parameter heißt ab dem SDK von macOS 27 anders.
    private static func options(_ tokens: Int) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: tokens)
        #endif
    }

    private func make(_ lang: String, _ about: String, _ screen: String, _ maxWords: Int) -> LanguageModelSession {
        let range = "\(max(2, maxWords - 3)) to \(maxWords)"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? lang
        var instructions = "You are a keyboard's inline text prediction. Each user message is an unfinished \(name) text. Reply only with the next \(range) \(name) words that continue it, in the same style and from the same writer's point of view. Never answer the text and never repeat words already written. If it stops in the middle of a word, start with the missing letters."
        if !about.isEmpty { instructions += " Notes about the writer, use only if relevant: \(about.prefix(600))" }
        if !screen.isEmpty { instructions += " Other text currently visible on the writer's screen, use only if relevant:\n\(screen.prefix(ScreenText.budget))" }
        func seg(_ s: String) -> Transcript.Segment { .text(.init(content: s)) }
        var entries: [Transcript.Entry] = [.instructions(.init(segments: [seg(instructions)], toolDefinitions: []))]
        for (p, r) in Self.shots[lang] ?? [] {
            entries.append(.prompt(.init(segments: [seg(p)])))
            entries.append(.response(.init(assetIDs: [], segments: [seg(r)])))
        }
        return LanguageModelSession(model: model, transcript: Transcript(entries: entries))
    }

    private static let shots: [String: [(String, String)]] = [
        "de": [
            ("Lieber Tom,\n\nich hoffe, dir geht es ", "gut und du hattest ein schönes Wochenende."),
            ("Könnten Sie mir bitte die Unterl", "agen bis Freitag zusenden?"),
            ("Wo liegt eigentlich der Bodensee? Ich war noch ", "nie dort und würde gern mal hinfahren."),
            ("ok bin gleich da, muss nur noch kurz", " was einkaufen und komme dann."),
        ],
        "en": [
            ("Dear Tom,\n\nI hope you are doing ", "well and had a great weekend."),
            ("Let me know if you have any ques", "tions or need anything else from me."),
            ("Where is Lake Como exactly? I have ", "never been there but would love to go."),
            ("ok almost there, just need to", " grab some groceries first."),
        ],
    ]
}
