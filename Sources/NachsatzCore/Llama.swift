import Foundation

/// Startet llama-server als Kindprozess, nur auf 127.0.0.1, mit zufälligem Port und Schlüssel,
/// ohne Netzzugriff und ohne Protokoll. Endet Nachsatz (auch durch Absturz), endet der Server mit.
public actor Llama {
    public static let modelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Nachsatz/Models/gemma-4-E2B.Q4_K_M.gguf")
    static let serverPaths = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]

    public nonisolated static var problem: String? {
        if !FileManager.default.fileExists(atPath: modelURL.path) { return "Gemma-Modelldatei fehlt" }
        if server == nil { return "llama.cpp ist nicht installiert" }
        return nil
    }
    private nonisolated static var server: String? {
        serverPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var process: Process?
    private var keepAlive: Pipe?
    private var port = 0
    private var key = ""
    private var ready = false
    private var lastStart = Date.distantPast
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    public init() {}

    public var isReady: Bool { ready && process?.isRunning == true }

    /// Startet den Server, falls nötig. Wartet nicht auf das Laden des Modells.
    public func start() {
        if process?.isRunning == true { return }
        guard let bin = Self.server, Self.problem == nil, Date().timeIntervalSince(lastStart) > 10 else { return }
        lastStart = Date()
        ready = false
        port = Int.random(in: 20000...59000)
        key = UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Die Hülle wartet auf das Ende der Leitung zu Nachsatz und beendet dann den Server.
        p.arguments = ["-c", "exec 3<&0; \"$@\" </dev/null & s=$!; trap 'kill $s' TERM; cat <&3 >/dev/null; kill $s", "sh", bin,
                       "-m", Self.modelURL.path, "--host", "127.0.0.1", "--port", "\(port)", "-c", "6144", "-np", "3", "-ngl", "99",
                       "--cache-ram", "0", "--swa-full", "--no-slots", "--no-webui", "--offline", "--log-disable", "--sleep-idle-seconds", "900"]
        var env = ProcessInfo.processInfo.environment
        env["LLAMA_API_KEY"] = key // nicht als Argument, sonst in der Prozessliste sichtbar
        p.environment = env
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p
        keepAlive = pipe
    }

    public func stop() {
        ready = false
        try? keepAlive?.fileHandleForWriting.close()
        keepAlive = nil
        process?.terminate()
        process = nil
        lastStart = .distantPast
    }

    /// Wartet bis zum Ladeende. false, wenn es nicht klappt.
    public func waitReady(seconds: Int) async -> Bool {
        start()
        for _ in 0..<(seconds * 5) {
            if await checkHealth() { return true }
            if process?.isRunning != true { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func checkHealth() async -> Bool {
        guard port > 0, let u = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var r = URLRequest(url: u); r.timeoutInterval = 1
        guard let (_, resp) = try? await session.data(for: r) else { return false }
        ready = (resp as? HTTPURLResponse)?.statusCode == 200
        return ready
    }

    /// Fortsetzung von `text`, bereits passend zum Anhängen. nil = kein Vorschlag.
    public func complete(_ text: String, about: String, screen: String = "", memory: String = "", prefer: [(word: String, bias: Double)] = [],
                         maxWords: Int, onPartial: Partial? = nil) async throws -> String? {
        if !ready { start(); guard await checkHealth() else { throw URLError(.cannotConnectToHost) } }
        let plan = Completion.plan(text)
        guard let plan else { return nil }
        let prompt = Completion.head(about: about, screen: screen, memory: memory) + plan.prompt
        let space = plan.forced.hasPrefix(" ")
        var biases: [[Double]] = [], words: [String] = []
        for p in prefer where p.bias > 0.05 {
            if let t = await firstToken((space ? " " : "") + p.word) { biases.append([Double(t), p.bias]); words.append(p.word.lowercased()) }
        }
        // Die Bevorzugung gilt für den ganzen Vorschlag. Wiederholt sich dadurch ein Wort, ohne sie neu.
        func repeats(_ f: String) -> Bool {
            let list = (Joiner.partialWord(text).lowercased() + f.lowercased()).split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.contains { x in list.filter { $0 == x }.count > 1 }
        }
        guard let onPartial else {
            let first = try await request(text, prompt, plan, biases, maxWords)
            if !biases.isEmpty, let f = first, repeats(f) { return try await request(text, prompt, plan, [], maxWords) }
            return first
        }
        switch try await stream(text, prompt, plan, biases, maxWords, reject: biases.isEmpty ? { _ in false } : repeats, onPartial) {
        case .done(let s): return s
        case .rejected: return try await request(text, prompt, plan, [], maxWords)
        }
    }

    /// Bekommt den bisherigen Vorschlag aus ganzen Wörtern. false bricht die Berechnung ab.
    public typealias Partial = @MainActor @Sendable (String) async -> Bool

    private enum Streamed { case done(String?), rejected }

    private func stream(_ text: String, _ prompt: String, _ plan: Completion.Plan, _ biases: [[Double]], _ maxWords: Int,
                        reject: (String) -> Bool, _ onPartial: Partial) async throws -> Streamed {
        var body = body(prompt, plan, biases, maxWords)
        body["stream"] = true
        do {
            lastUse = Date()
            let (bytes, resp) = try await session.bytes(for: urlRequest("completion", body))
            defer { bytes.task.cancel() } // Verbindung zu: der Server hört sofort auf
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .done(nil) }
            var out = "", cut = false, last = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                out += o["content"] as? String ?? ""
                if o["stop"] as? Bool == true { cut = o["stop_type"] as? String == "limit"; break }
                guard let p = Completion.partial(text: text, output: out, forced: plan.forced, maxWords: maxWords), p != last else { continue }
                if reject(p) { return .rejected }
                last = p
                if !(await onPartial(p)) { return .done(nil) }
                // Satzende oder volle Länge: der Rest der Rechnung würde verworfen.
                if Completion.complete(p, maxWords: maxWords) { return .done(p) }
            }
            let s = Completion.finish(text: text, output: out, forced: plan.forced, cut: cut, maxWords: maxWords)
            if let s, reject(s) { return .rejected }
            return .done(s)
        } catch let e as URLError where e.code != .cancelled {
            ready = false
            throw e
        }
    }

    /// Modell wecken und den Feldtext schon einlesen, ohne etwas zu erzeugen.
    public func warm(_ text: String, about: String, screen: String = "", memory: String) async {
        guard ready, let plan = Completion.plan(text) else { return }
        let prompt = Completion.head(about: about, screen: screen, memory: memory) + plan.prompt
        lastUse = Date()
        _ = try? await post("completion", ["prompt": prompt, "n_predict": 0, "temperature": 0, "cache_prompt": true, "id_slot": 0])
    }
    public private(set) var lastUse = Date.distantPast

    private func body(_ prompt: String, _ plan: Completion.Plan, _ biases: [[Double]], _ maxWords: Int) -> [String: Any] {
        var body: [String: Any] = ["prompt": prompt, "n_predict": maxWords * 2, "temperature": 0, "cache_prompt": true, "id_slot": 0,
                                   "stop": ["\n"], "grammar": plan.grammar]
        if !biases.isEmpty { body["logit_bias"] = biases.map { [Int($0[0]), $0[1]] as [Any] } }
        return body
    }

    private func request(_ text: String, _ prompt: String, _ plan: Completion.Plan, _ biases: [[Double]], _ maxWords: Int) async throws -> String? {
        let body = body(prompt, plan, biases, maxWords)
        do {
            lastUse = Date()
            guard let o = try await post("completion", body), let out = o["content"] as? String else { return nil }
            return Completion.finish(text: text, output: out, forced: plan.forced,
                                     cut: o["stop_type"] as? String == "limit", maxWords: maxWords)
        } catch let e as URLError where e.code != .cancelled {
            ready = false // beim nächsten Mal neu verbinden oder starten
            throw e
        }
    }

    /// Ergänzung mitten im Satz, passend mit Leerzeichen. Eigener Platz im Server, damit nichts verdrängt wird.
    public func fillGap(before: String, after: String) async throws -> String? {
        guard let (l, r) = Gap.context(before: before, after: after) else { return nil }
        if !ready { start(); guard await checkHealth() else { throw URLError(.cannotConnectToHost) } }
        guard let o = try await post("completion", ["prompt": Gap.prompt(l, r), "n_predict": 10, "temperature": 0, "cache_prompt": true,
                                                    "id_slot": 1, "stop": ["\n"]]), let out = o["content"] as? String else { return nil }
        return Gap.finish(out, left: before, right: String(after.prefix { $0 != "\n" }))
    }

    /// Korrigierter Satz oder nil.
    public func correct(_ sentence: String) async throws -> String? {
        guard sentence.count <= 300 else { return nil }
        if !ready { start(); guard await checkHealth() else { throw URLError(.cannotConnectToHost) } }
        guard let o = try await post("completion", ["prompt": Corrector.prompt(sentence), "n_predict": 24 + sentence.count / 2, "temperature": 0,
                                                    "cache_prompt": true, "id_slot": 2, "stop": ["\n"]]),
              o["stop_type"] as? String != "limit", let out = o["content"] as? String else { return nil }
        let t = out.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func urlRequest(_ path: String, _ body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any]? {
        let (d, resp) = try await session.data(for: urlRequest(path, body))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private var tokenCache: [String: Int] = [:]

    /// Erster Baustein eines Worts. Zu kurze Bruchstücke (nil) würden andere Wörter mitziehen.
    private func firstToken(_ w: String) async -> Int? {
        if let t = tokenCache[w] { return t < 0 ? nil : t }
        guard let o = try? await post("tokenize", ["content": w, "add_special": false, "with_pieces": true]),
              let t = (o["tokens"] as? [[String: Any]])?.first, let id = t["id"] as? Int else { return nil }
        let piece = t["piece"] as? String ?? ""
        let ok = piece == w || piece.trimmingCharacters(in: .whitespaces).count >= 3
        if tokenCache.count > 4000 { tokenCache = [:] }
        tokenCache[w] = ok ? id : -1
        return ok ? id : nil
    }
}

/// Reine Textlogik für Basismodelle.
public enum Completion {
    public struct Plan { public var prompt: String; public var forced: String; public var grammar: String }

    /// Kontext vor dem Feldtext. Was sich selten ändert, steht vorn, damit der Prompt-Zwischenspeicher hält.
    public static func head(about: String, screen: String, memory: String) -> String {
        var out = ""
        if !about.isEmpty { out += String(about.prefix(600)) + "\n\n" }
        if !screen.isEmpty { out += String(screen.prefix(ScreenText.budget)) + "\n\n" }
        if !memory.isEmpty { out += memory + "\n\n" }
        return out
    }

    /// Nimmt das angefangene Wort zurück und gibt es als erzwungenen Anfang vor. So sieht
    /// das Modell keine Wortfetzen, die es aus dem Training nicht kennt.
    public static func plan(_ text: String) -> Plan? {
        let partial = String(text.reversed().prefix { !$0.isWhitespace }.reversed())
        guard partial.count <= 40 else { return nil }
        var prompt = String(text.dropLast(partial.count)), lead = ""
        while prompt.last == " " { prompt.removeLast(); lead = " " }
        prompt = String(prompt.suffix(1200))
        let forced = prompt.isEmpty ? partial : lead + partial
        let esc = forced.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Plan(prompt: prompt, forced: forced,
                    grammar: "root ::= " + (esc.isEmpty ? "" : "\"\(esc)\" ") + "[^\\n<>*#|_`{}\\\\]*")
    }

    /// Bisher fertige ganze Wörter einer laufenden Ausgabe, sonst nil.
    public static func partial(text: String, output: String, forced: String, maxWords: Int) -> String? {
        guard output.hasPrefix(forced), let i = output.lastIndex(where: { $0.isWhitespace }) else { return nil }
        let whole = String(output[..<i])
        guard whole.count > forced.count else { return nil }
        // Ein einzelnes Satzzeichen oder eine Aufzählung kann sich noch ändern.
        guard let s = finish(text: text, output: whole, forced: forced, cut: false, maxWords: maxWords) else { return nil }
        return s
    }

    /// true, wenn weitere Ausgabe den Vorschlag nicht mehr verlängern würde.
    public static func complete(_ s: String, maxWords: Int) -> Bool {
        let w = s.split(separator: " ")
        guard let last = w.last, let l = last.last else { return false }
        return w.count >= maxWords || "!?".contains(l) || (l == "." && endsSentence(String(last)))
    }

    public static func finish(text: String, output: String, forced: String, cut: Bool, maxWords: Int) -> String? {
        var out = output.hasPrefix(forced) ? String(output.dropFirst(forced.count)) : output
        out = out.components(separatedBy: "\n")[0]
        if text.last?.isWhitespace ?? true { out = String(out.drop { $0.isWhitespace }) }
        var words: [String] = [], rest = out
        while !rest.isEmpty {
            let c = Joiner.nextChunk(of: rest)
            if c.trimmingCharacters(in: .whitespaces).isEmpty { break }
            words.append(c); rest.removeFirst(c.count)
        }
        if cut, words.count > 1, words.count <= maxWords { words.removeLast() } // letztes Wort evtl. abgeschnitten
        var take = ""
        for (i, w) in words.prefix(maxWords).enumerated() {
            let t = w.trimmingCharacters(in: .whitespaces)
            if i > 0, isListMarker(t), let l = take.last, ",.:;!?".contains(l) { break } // beginnende Aufzählung
            take += w
            if let l = take.last, "!?".contains(l) || (l == "." && endsSentence(t)) { break }
        }
        while let l = take.last, l.isWhitespace || "(„\"-–:;".contains(l) { take.removeLast() }
        guard take.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // Wiederholt nur, was gerade schon dasteht.
        let flat = take.trimmingCharacters(in: .whitespaces).lowercased()
        if flat.split(separator: " ").count >= 3, text.suffix(400).lowercased().contains(flat) { return nil }
        return take
    }

    /// Punkt am Satzende, nicht nach Zahl, Buchstabe oder Abkürzung.
    static func endsSentence(_ w: String) -> Bool {
        let core = w.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if core.isEmpty { return true }
        if core.allSatisfy(\.isNumber) || core.count == 1 { return false }
        return !["bzw", "ca", "dr", "nr", "str", "prof", "evtl", "ggf", "inkl", "vgl", "st", "mr", "mrs", "ms", "z.b", "d.h", "u.a", "e.g", "i.e", "vs", "max", "min", "tel"].contains(core)
    }

    private static func isListMarker(_ s: String) -> Bool {
        guard let l = s.last, ".)".contains(l), s.count <= 3 else { return false }
        return s.dropLast().allSatisfy(\.isNumber) && s.count > 1
    }
}
