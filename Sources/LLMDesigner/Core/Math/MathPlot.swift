import Foundation

/// How a plot under a formula is drawn. Stored in the picture's Markdown attributes:
/// `![…](Bilder/plot-….png){width=70% .plot x=-5:5 y=auto grid=true params=a:1;b:2}`.
struct PlotSpec: Equatable, Sendable {
    var xMin: Double = -5
    var xMax: Double = 5
    /// nil: chosen from the values.
    var yMin: Double?
    var yMax: Double?
    var grid = true
    /// Values of the formula's free letters (a, k, α, …).
    var parameters: [String: Double] = [:]

    var markdownAttributes: [String] {
        var tokens = [".plot", "x=\(Self.format(xMin)):\(Self.format(xMax))"]
        if let yMin, let yMax { tokens.append("y=\(Self.format(yMin)):\(Self.format(yMax))") } else { tokens.append("y=auto") }
        tokens.append("grid=\(grid)")
        if !parameters.isEmpty {
            tokens.append("params=" + parameters.keys.sorted().map { "\($0):\(Self.format(parameters[$0] ?? 1))" }.joined(separator: ";"))
        }
        return tokens
    }

    /// Reads the attributes after `.plot`.
    mutating func read(_ key: String, _ value: String) {
        func range(_ text: String) -> (Double, Double)? {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 && parts[0] < parts[1] ? (parts[0], parts[1]) : nil
        }
        switch key {
        case "x": if let (low, high) = range(value) { xMin = low; xMax = high }
        case "y":
            if let (low, high) = range(value) { yMin = low; yMax = high } else { yMin = nil; yMax = nil }
        case "grid": grid = value != "false"
        case "params":
            for pair in value.split(separator: ";") {
                let parts = pair.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let number = Double(parts[1]) { parameters[String(parts[0])] = number }
            }
        default: break
        }
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%g", value)
    }
}

enum PlotError: LocalizedError {
    case notPlottable(String)
    case noPython
    case noValues
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPlottable(let reason): "Diese Formel lässt sich nicht zeichnen: \(reason)"
        case .noPython: "Für Plots wird Python 3 mit numpy und matplotlib gebraucht (z. B. Miniconda unter ~/miniconda3)."
        case .noValues: "Im gewählten Bereich hat die Funktion keine Werte."
        case .failed(let log): log.isEmpty ? "Der Plot konnte nicht erstellt werden." : "Der Plot konnte nicht erstellt werden:\n\(log)"
        }
    }
}

/// The functions of a formula, ready for numpy: one curve per line.
struct PlotProgram: Equatable {
    struct Curve: Equatable {
        /// The line as LaTeX, for the legend.
        var label: String
        /// A numpy expression in `x`.
        var expression: String
    }

    var curves: [Curve]
    /// The axis variable as written (x, t, φ, …).
    var variable: String
    /// Free letters in order of appearance; they become sliders.
    var parameters: [String]
}

/// Translates the formula tree into numpy code. Only what is understood gets through; everything else is an
/// error, so the generated code never contains text from the document.
enum PlotTranslator {
    static func program(for latex: String) throws -> PlotProgram {
        let formula = MathFormula(latex: latex)
        var curves: [PlotProgram.Curve] = []
        var parameters: [String] = []
        var axis: String?
        for line in formula.lines where !line.isEmpty {
            let items = line.items.filter { $0.kind != .symbol("&") }
            let equals = items.indices.filter { items[$0].kind == .symbol("=") }
            let left = equals.first.map { Array(items[..<$0]) } ?? []
            let right = equals.last.map { Array(items[($0 + 1)...]) } ?? items
            guard !right.isEmpty else { continue }
            let variable = variable(from: left, expression: right)
            axis = axis ?? variable
            var translator = Translator(variable: variable, parameters: parameters)
            let expression = try translator.expression(right)
            parameters = translator.parameters
            let label = MathLaTeXWriter(caret: nil, placeholders: false).row(MathRow(items.map { $0.copy() }))
            curves.append(.init(label: label, expression: expression))
        }
        guard !curves.isEmpty else { throw PlotError.notPlottable("Es gibt keinen Term, der von einer Variablen abhängt.") }
        return PlotProgram(curves: curves, variable: axis ?? "x", parameters: parameters)
    }

    /// The variable of `f(x) = …`, else x (or t) when the term has it.
    private static func variable(from left: [MathNode], expression: [MathNode]) -> String {
        for (index, node) in left.enumerated() {
            if case .group(let open, _) = node.kind, open == "(", node.slots[0].count == 1, case .symbol(let token) = node.slots[0].items[0].kind {
                return token
            }
            if node.kind == .symbol("("), index + 2 < left.count, left[index + 2].kind == .symbol(")"), case .symbol(let token) = left[index + 1].kind {
                return token
            }
        }
        var letters: [String] = []
        func collect(_ nodes: [MathNode]) {
            for node in nodes {
                if case .symbol(let token) = node.kind { letters.append(token) }
                node.slots.forEach { collect($0.items) }
            }
        }
        collect(expression)
        for candidate in ["x", "t", "\\varphi", "\\phi", "\\theta", "s", "u", "z"] where letters.contains(candidate) { return candidate }
        return "x"
    }

    private struct Translator {
        let variable: String
        var parameters: [String]

        private enum Piece {
            case operand(String)
            case operation(String)
        }

        static let functions: [String: String] = [
            "\\sin": "np.sin", "\\cos": "np.cos", "\\tan": "np.tan", "\\arcsin": "np.arcsin", "\\arccos": "np.arccos",
            "\\arctan": "np.arctan", "\\sinh": "np.sinh", "\\cosh": "np.cosh", "\\tanh": "np.tanh", "\\ln": "np.log",
            "\\lg": "np.log10", "\\log": "np.log10", "\\exp": "np.exp", "\\operatorname{sgn}": "np.sign",
            "\\operatorname{sign}": "np.sign", "\\operatorname{abs}": "np.abs",
        ]
        static let reciprocal: [String: String] = ["\\cot": "np.tan", "\\sec": "np.cos", "\\csc": "np.sin", "\\coth": "np.tanh"]
        static let ignored: Set<String> = ["\\,", "\\;", "\\:", "\\!", "\\quad", "\\qquad", "&", "\\left.", "\\right."]

        init(variable: String, parameters: [String]) {
            self.variable = variable
            self.parameters = parameters
        }

        mutating func expression(_ items: [MathNode]) throws -> String {
            var pieces: [Piece] = []
            func operand(_ text: String) {
                if case .operand = pieces.last { pieces.append(.operation("*")) }
                pieces.append(.operand(text))
            }
            var index = 0
            while index < items.count {
                let node = items[index]
                switch node.kind {
                case .symbol(let token):
                    if token.first?.isNumber == true || token == "." {
                        var literal = ""
                        while index < items.count, case .symbol(let digit) = items[index].kind {
                            if digit.first?.isNumber == true { literal += digit }
                            else if (digit == "." || digit == ","), index + 1 < items.count, case .symbol(let next) = items[index + 1].kind,
                                    next.first?.isNumber == true, !literal.contains(".") { literal += "." }
                            else { break }
                            index += 1
                        }
                        guard let value = Double(literal) else { throw PlotError.notPlottable("„\(literal)“ ist keine Zahl.") }
                        operand(PlotSpec.format(value))
                        continue
                    }
                    switch token {
                    case "+", "-": pieces.append(.operation(token))
                    case "\\cdot", "\\times", "*": pieces.append(.operation("*"))
                    case "/", "\\div": pieces.append(.operation("/"))
                    case "(", "[":
                        let close = token == "(" ? ")" : "]"
                        guard let end = matching(items, from: index, open: token, close: close) else { throw PlotError.notPlottable("Eine Klammer ist nicht geschlossen.") }
                        operand("(" + (try expression(Array(items[(index + 1)..<end]))) + ")")
                        index = end
                    case "|":
                        guard let end = items[(index + 1)...].firstIndex(where: { $0.kind == .symbol("|") }) else { throw PlotError.notPlottable("Ein Betragsstrich ist nicht geschlossen.") }
                        operand("np.abs(" + (try expression(Array(items[(index + 1)..<end]))) + ")")
                        index = end
                    case _ where Self.ignored.contains(token): break
                    case "!": throw PlotError.notPlottable("Fakultäten werden noch nicht gezeichnet.")
                    case "'": throw PlotError.notPlottable("Ableitungen werden noch nicht gezeichnet.")
                    case "\\infty": throw PlotError.notPlottable("∞ ist kein Wert.")
                    case variable: operand("x")
                    case "e": operand("np.e")
                    case "\\pi": operand("np.pi")
                    default:
                        let isGreek = MathSymbols.greek.contains(token)
                        guard (token.count == 1 && token.first!.isLetter) || isGreek else {
                            throw PlotError.notPlottable("„\(token)“ kann nicht gerechnet werden.")
                        }
                        var name = isGreek ? String(token.dropFirst()) : token
                        // A subscript is part of the name: a_1.
                        if index + 1 < items.count, let sub = items[index + 1].subscript {
                            name += "_" + (try plain(sub))
                            if let sup = items[index + 1].superscript {
                                operand("(" + parameter(name) + ")**(" + (try expression(sup.items)) + ")")
                            } else {
                                operand(parameter(name))
                            }
                            index += 2
                            continue
                        }
                        operand(parameter(name))
                    }
                case .function(let name):
                    var power: String?
                    var base: String?
                    if index + 1 < items.count, items[index + 1].isScripts {
                        if let sup = items[index + 1].superscript { power = try expression(sup.items) }
                        if let sub = items[index + 1].subscript { base = try expression(sub.items) }
                        index += 1
                    }
                    let (argument, last) = try self.argument(items, after: index)
                    index = last
                    var call: String
                    if let function = Self.functions[name] {
                        call = "\(function)(\(argument))"
                        if name == "\\log", let base { call = "(np.log(\(argument))/np.log(\(base)))" }
                    } else if let function = Self.reciprocal[name] {
                        call = "(1/\(function)(\(argument)))"
                    } else {
                        throw PlotError.notPlottable("„\(name)“ wird noch nicht gezeichnet.")
                    }
                    if let power { call = "(\(call))**(\(power))" }
                    operand(call)
                case .largeOperator:
                    throw PlotError.notPlottable("Summen, Produkte, Integrale und Grenzwerte werden noch nicht gezeichnet.")
                case .fraction:
                    operand("((" + (try expression(node.slots[0].items)) + ")/(" + (try expression(node.slots[1].items)) + "))")
                case .root:
                    operand("np.sqrt(" + (try expression(node.slots[0].items)) + ")")
                case .nthRoot:
                    let degree = try expression(node.slots[0].items)
                    let radicand = try expression(node.slots[1].items)
                    if let value = Double(degree), value == value.rounded(), Int(value) % 2 == 1 {
                        operand("(np.sign(\(radicand))*np.abs(\(radicand))**(1/\(degree)))")
                    } else {
                        operand("np.power(\(radicand), 1/(\(degree)))")
                    }
                case .scripts:
                    guard let sup = node.superscript else { throw PlotError.notPlottable("Ein Index ohne Bedeutung zum Rechnen.") }
                    guard case .operand(let base) = pieces.last else { throw PlotError.notPlottable("Eine Hochzahl ohne Basis.") }
                    pieces[pieces.count - 1] = .operand("(\(base))**(" + (try expression(sup.items)) + ")")
                case .group(let left, _):
                    let inner = try expression(node.slots[0].items)
                    switch left {
                    case "|", "\\|", "\\vert", "\\Vert", "\\lvert": operand("np.abs(\(inner))")
                    case "\\lfloor": operand("np.floor(\(inner))")
                    case "\\lceil": operand("np.ceil(\(inner))")
                    default: operand("(\(inner))")
                    }
                case .binomial, .accent, .style, .text, .matrix, .raw:
                    throw PlotError.notPlottable("Teile wie Matrizen, Text oder Akzente lassen sich nicht rechnen.")
                }
                index += 1
            }
            guard !pieces.isEmpty else { throw PlotError.notPlottable("Ein Teil der Formel ist leer.") }
            if case .operation = pieces.last { throw PlotError.notPlottable("Die Formel ist unvollständig.") }
            return pieces.map { piece in
                switch piece {
                case .operand(let text): text
                case .operation(let text): " \(text) "
                }
            }.joined()
        }

        /// A function's argument: a bracket right after it, else everything up to the next + or − (or relation).
        private mutating func argument(_ items: [MathNode], after index: Int) throws -> (String, Int) {
            let start = index + 1
            guard start < items.count else { throw PlotError.notPlottable("Einer Funktion fehlt ihr Argument.") }
            if case .group = items[start].kind {
                return (try expression(items[start].slots[0].items), start)
            }
            if items[start].kind == .symbol("("), let end = matching(items, from: start, open: "(", close: ")") {
                return (try expression(Array(items[(start + 1)..<end])), end)
            }
            var end = start
            while end < items.count {
                if case .symbol(let token) = items[end].kind, MathSymbols.operators.contains(token) { break }
                if case .function = items[end].kind, end > start { break }
                end += 1
            }
            guard end > start else { throw PlotError.notPlottable("Einer Funktion fehlt ihr Argument.") }
            return (try expression(Array(items[start..<end])), end - 1)
        }

        private func matching(_ items: [MathNode], from index: Int, open: String, close: String) -> Int? {
            var depth = 0
            for position in index..<items.count {
                if items[position].kind == .symbol(open) { depth += 1 }
                if items[position].kind == .symbol(close) {
                    depth -= 1
                    if depth == 0 { return position }
                }
            }
            return nil
        }

        /// A subscript as part of a name; only letters and digits.
        private func plain(_ row: MathRow) throws -> String {
            let text = row.items.map { node -> String in
                if case .symbol(let token) = node.kind { return token.hasPrefix("\\") ? String(token.dropFirst()) : token }
                return "?"
            }.joined()
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw PlotError.notPlottable("Ein Index aus „\(text)“ taugt nicht als Name.")
            }
            return text
        }

        /// A free letter: a parameter with its own Python name.
        private mutating func parameter(_ name: String) -> String {
            if !parameters.contains(name) { parameters.append(name) }
            return PlotTranslator.identifier(for: name)
        }
    }

    /// The Python name of a parameter: only ASCII letters, digits and "_", so nothing from the document ends up as code.
    static func identifier(for parameter: String) -> String {
        "p_" + String(parameter.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }
}

/// Runs Python with numpy and matplotlib to draw a plot: a light PNG for paper, a dark one for the dark sheet,
/// and a PDF for LaTeX.
actor PlotRenderer {
    static let shared = PlotRenderer()

    struct Output: Sendable {
        let directory: URL
        var light: URL { directory.appendingPathComponent("light.png") }
        var dark: URL { directory.appendingPathComponent("dark.png") }
        var pdf: URL { directory.appendingPathComponent("plot.pdf") }
    }

    private var python: URL??

    private static let candidates = [
        "~/miniconda3/bin/python3", "~/anaconda3/bin/python3", "~/miniforge3/bin/python3", "~/mambaforge/bin/python3",
        "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
    ]

    /// A Python that has numpy and matplotlib; looked for once.
    func pythonExecutable() async -> URL? {
        if let python { return python }
        for path in Self.candidates {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if (try? await run(url, ["-I", "-c", "import numpy, matplotlib"], timeout: 30)) != nil {
                python = .some(url)
                return url
            }
        }
        python = .some(nil)
        return nil
    }

    func render(_ program: PlotProgram, spec: PlotSpec) async throws -> Output {
        guard let python = await pythonExecutable() else { throw PlotError.noPython }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesigner-Plot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("plot.py")
        let config = directory.appendingPathComponent("config.json")
        try Self.script(for: program).write(to: script, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: Self.configuration(program, spec)).write(to: config)
        do {
            _ = try await run(python, ["-I", script.path, config.path, directory.path], timeout: 40)
        } catch PlotError.failed(let log) where log.contains("NOVALUES") {
            throw PlotError.noValues
        }
        let output = Output(directory: directory)
        guard FileManager.default.fileExists(atPath: output.light.path) else { throw PlotError.failed("") }
        return output
    }

    private static func configuration(_ program: PlotProgram, _ spec: PlotSpec) -> [String: Any] {
        var parameters: [String: Double] = [:]
        for name in program.parameters { parameters[PlotTranslator.identifier(for: name)] = spec.parameters[name] ?? 1 }
        let variable = program.variable
        return [
            "xmin": spec.xMin, "xmax": spec.xMax,
            "ymin": spec.yMin.map { $0 as Any } ?? NSNull(), "ymax": spec.yMax.map { $0 as Any } ?? NSNull(),
            "grid": spec.grid,
            "params": parameters,
            // matplotlib's mathtext drops the delimiters of \left( … \right); plain ones read the same in a legend.
            "labels": program.curves.map { $0.label.replacingOccurrences(of: #"\\(left|right)(?![A-Za-z])\.?"#, with: "", options: .regularExpression) },
            "plainLabels": program.curves.indices.map { program.curves.count == 1 ? "" : "Kurve \($0 + 1)" },
            "xlabel": "$\(variable)$",
            "themes": [
                "light": ["background": "#FFFFFF", "text": "#1C1C1F", "axis": "#8A8A92", "grid": "#E6E6EC",
                          "colors": ["#6A54E0", "#E0546A", "#1F9D57", "#D98A00", "#2B7FD9", "#B04CC9"]],
                "dark": ["background": "#141417", "text": "#E8E8EC", "axis": "#7A7A84", "grid": "#26262C",
                         "colors": ["#A996FF", "#FF8FA3", "#5FD38A", "#F2B14C", "#6FD3FF", "#E29BFF"]],
            ],
        ]
    }

    private static func script(for program: PlotProgram) -> String {
        let parameters = program.parameters.map { "\(PlotTranslator.identifier(for: $0)) = float(P[\"\(PlotTranslator.identifier(for: $0))\"])" }.joined(separator: "\n")
        let functions = program.curves.enumerated().map { "def f\($0.offset)(x):\n    return \($0.element.expression)" }.joined(separator: "\n\n")
        let names = program.curves.indices.map { "f\($0)" }.joined(separator: ", ")
        return """
        import json, sys, warnings
        warnings.filterwarnings("ignore")
        import numpy as np
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        cfg = json.load(open(sys.argv[1], encoding="utf-8"))
        out = sys.argv[2]
        P = cfg["params"]
        \(parameters)

        \(functions)

        funcs = [\(names)]
        x = np.linspace(cfg["xmin"], cfg["xmax"], 2001)
        ys = []
        with np.errstate(all="ignore"):
            for f in funcs:
                y = np.asarray(f(x))
                if np.iscomplexobj(y):
                    y = np.where(np.abs(y.imag) < 1e-12, y.real, np.nan)
                y = np.asarray(y, dtype=float) * np.ones_like(x)
                y[~np.isfinite(y)] = np.nan
                ys.append(y)
        finite = [y[np.isfinite(y)] for y in ys]
        vals = np.concatenate(finite) if finite else np.array([])
        if vals.size == 0:
            print("NOVALUES", file=sys.stderr)
            sys.exit(3)
        lo, hi = float(np.min(vals)), float(np.max(vals))
        p_lo, p_hi = np.percentile(vals, [3, 97])
        if (hi - lo) > 6 * max(p_hi - p_lo, 1e-12):
            lo, hi = float(p_lo), float(p_hi)
        if hi - lo < 1e-9:
            lo, hi = lo - 1, hi + 1
        pad = (hi - lo) * 0.08
        lo, hi = lo - pad, hi + pad
        if cfg["ymin"] is not None and cfg["ymax"] is not None:
            lo, hi = cfg["ymin"], cfg["ymax"]
        span = hi - lo
        for y in ys:
            with np.errstate(all="ignore"):
                jumps = np.abs(np.diff(y)) > span * 0.5
            y[1:][jumps] = np.nan

        def draw(theme, path, labels):
            t = cfg["themes"][theme]
            plt.rcParams.update({"font.size": 10, "mathtext.fontset": "cm", "axes.unicode_minus": True})
            fig, ax = plt.subplots(figsize=(6.4, 4.0))
            fig.patch.set_facecolor(t["background"])
            ax.set_facecolor(t["background"])
            for spine in ax.spines.values():
                spine.set_color(t["axis"])
            ax.tick_params(colors=t["text"])
            if lo < 0 < hi:
                ax.axhline(0, color=t["axis"], lw=0.9, zorder=1)
            if cfg["xmin"] < 0 < cfg["xmax"]:
                ax.axvline(0, color=t["axis"], lw=0.9, zorder=1)
            for i, y in enumerate(ys):
                ax.plot(x, y, color=t["colors"][i % len(t["colors"])], lw=2.0, label=labels[i] or None, zorder=3)
            ax.set_xlim(cfg["xmin"], cfg["xmax"])
            ax.set_ylim(lo, hi)
            if cfg["grid"]:
                ax.grid(True, color=t["grid"], lw=0.7, zorder=0)
            ax.set_xlabel(cfg["xlabel"], color=t["text"])
            if any(labels):
                ax.legend(frameon=False, labelcolor=t["text"])
            fig.tight_layout()
            fig.savefig(path, dpi=200, facecolor=t["background"])
            plt.close(fig)

        labels = ["$" + label + "$" for label in cfg["labels"]]
        try:
            draw("light", out + "/light.png", labels)
        except Exception:
            labels = cfg["plainLabels"]
            try:
                draw("light", out + "/light.png", labels)
            except Exception:
                cfg["xlabel"] = ""
                draw("light", out + "/light.png", labels)
        draw("dark", out + "/dark.png", labels)
        draw("light", out + "/plot.pdf", labels)
        """
    }

    private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MPLBACKEND"] = "Agg"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { finished in
                timer.cancel()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    continuation.resume(throwing: PlotError.failed(lines.suffix(3).joined(separator: "\n")))
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                continuation.resume(throwing: PlotError.failed(error.localizedDescription))
            }
        }
    }
}
