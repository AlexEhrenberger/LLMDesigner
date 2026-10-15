import Foundation

/// A range of an axis or of a curve's parameter.
struct PlotRange: Equatable, Sendable {
    var low: Double
    var high: Double

    init(_ low: Double, _ high: Double) {
        self.low = low
        self.high = high
    }

    var token: String { PlotSpec.format(low) + ":" + PlotSpec.format(high) }
    var values: [Double] { [low, high] }

    static func parse(_ text: String) -> PlotRange? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[0] < parts[1] ? PlotRange(parts[0], parts[1]) : nil
    }

    static let fullTurn = PlotRange(0, 2 * Double.pi)
}

/// How surfaces and vector fields are drawn.
enum PlotStyle: String, CaseIterable, Sendable {
    case surface, wireframe, contour, heatmap, streamlines, arrows

    var label: String {
        switch self {
        case .surface: "Fläche"
        case .wireframe: "Gitter"
        case .contour: "Höhenlinien"
        case .heatmap: "Farbkarte"
        case .streamlines: "Stromlinien"
        case .arrows: "Pfeile"
        }
    }

    /// Drawn flat, seen from above.
    var isFlat: Bool { self == .contour || self == .heatmap }

    static let surfaceStyles: [PlotStyle] = [.surface, .wireframe, .contour, .heatmap]
    static let vectorStyles: [PlotStyle] = [.streamlines, .arrows]
}

/// How a plot under a formula is drawn. Stored in the picture's Markdown attributes:
/// `![…](Bilder/plot-….png){width=70% .plot x=-5:5 y=auto grid=true params=a:1;b:2}`; surfaces and curves in
/// space add `z=…`, `t=…`, `u=…`, `v=…`, `style=…` and `view=Neigung:Drehung`.
struct PlotSpec: Equatable, Sendable {
    var x = PlotRange(-5, 5)
    /// Curves: the value axis (nil: chosen from the values). Plane and space: the second coordinate (nil: like x).
    var y: PlotRange?
    /// Surfaces: the value axis (nil: chosen from the values). Space: the third coordinate (nil: like x).
    var z: PlotRange?
    /// The parameter of a curve (t, φ); nil: one full turn.
    var t: PlotRange?
    /// The parameters of a surface; nil: one full turn.
    var u: PlotRange?
    var v: PlotRange?
    /// nil: a surface as a surface, a vector field with stream lines.
    var style: PlotStyle?
    var elevation = Self.defaultElevation
    var azimuth = Self.defaultAzimuth
    var grid = true
    /// Zeros and extrema of curves, with their coordinates.
    var marks = false
    /// Values of the formula's free letters (a, k, α, …).
    var parameters: [String: Double] = [:]

    static let defaultElevation: Double = 28
    static let defaultAzimuth: Double = -56

    var markdownAttributes: [String] {
        var tokens = [".plot", "x=\(x.token)", "y=\(y?.token ?? "auto")"]
        for (key, range) in [("z", z), ("t", t), ("u", u), ("v", v)] {
            if let range { tokens.append("\(key)=\(range.token)") }
        }
        if let style { tokens.append("style=\(style.rawValue)") }
        if elevation != Self.defaultElevation || azimuth != Self.defaultAzimuth {
            tokens.append("view=\(Self.format(elevation)):\(Self.format(azimuth))")
        }
        tokens.append("grid=\(grid)")
        if marks { tokens.append("marks=true") }
        if !parameters.isEmpty {
            tokens.append("params=" + parameters.keys.sorted().map { "\($0):\(Self.format(parameters[$0] ?? 1))" }.joined(separator: ";"))
        }
        return tokens
    }

    /// Reads the attributes after `.plot`.
    mutating func read(_ key: String, _ value: String) {
        switch key {
        case "x": if let range = PlotRange.parse(value) { x = range }
        case "y": y = PlotRange.parse(value)
        case "z": z = PlotRange.parse(value)
        case "t": t = PlotRange.parse(value)
        case "u": u = PlotRange.parse(value)
        case "v": v = PlotRange.parse(value)
        case "style": style = PlotStyle(rawValue: value)
        case "view":
            let parts = value.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { elevation = parts[0]; azimuth = parts[1] }
        case "grid": grid = value != "false"
        case "marks": marks = value == "true"
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

    /// A number as the plot settings show it: multiples of π as such ("2π", "π/2"), else with a decimal comma.
    static func display(_ value: Double) -> String {
        let quarters = value / (Double.pi / 4)
        if abs(value) > 1e-9, abs(quarters - quarters.rounded()) < 1e-6, value != value.rounded() {
            let n = Int(quarters.rounded())
            let divisor = n % 4 == 0 ? 1 : (n % 2 == 0 ? 2 : 4)
            let factor = n * divisor / 4
            let sign = factor < 0 ? "−" : ""
            let magnitude = abs(factor) == 1 ? "" : String(abs(factor))
            return sign + magnitude + "π" + (divisor == 1 ? "" : "/\(divisor)")
        }
        return format(value).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
    }

    /// Reads "1,5", "-2", "2π", "pi/2", "−π".
    static func parseNumber(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "pi", with: "π")
        guard !text.isEmpty else { return nil }
        guard text.contains("π") else { return Double(text).flatMap { $0.isFinite ? $0 : nil } }
        var divisor = 1.0
        if let slash = text.firstIndex(of: "/") {
            guard let value = Double(text[text.index(after: slash)...]), value != 0 else { return nil }
            divisor = value
            text = String(text[..<slash])
        }
        let factorText = text.replacingOccurrences(of: "π", with: "").replacingOccurrences(of: "*", with: "")
        let factor: Double
        switch factorText {
        case "": factor = 1
        case "-": factor = -1
        default:
            guard let value = Double(factorText) else { return nil }
            factor = value
        }
        return factor * Double.pi / divisor
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

/// The graphs of a formula, ready for numpy: one per line, except that `x = …`, `y = …`, `z = …` lines of the same
/// parameter make one curve or surface together.
struct PlotProgram: Equatable {
    enum Kind: String, Sendable {
        /// y = f(x)
        case curve
        /// r = f(φ)
        case polar
        /// (x(t), y(t)) or (x(t), y(t), z(t))
        case parametric
        /// F(x, y) = G(x, y)
        case implicit
        /// F(x, y) ≤ G(x, y)
        case region
        /// z = f(x, y)
        case surface
        /// (x(u, v), y(u, v), z(u, v))
        case parametricSurface
        /// F(x, y, z) = G(x, y, z)
        case implicitSurface
        /// f(x, y, z): drawn as three level surfaces
        case scalarField
        /// (P(x, y), Q(x, y))
        case vectors
        /// (P, Q, R)(x, y, z)
        case vectors3d
    }

    struct Item: Equatable {
        var kind: Kind
        /// The line as LaTeX, for the legend.
        var label: String
        /// The variables as written (x, t, φ, …); the Python function takes them in this order as a0, a1, a2.
        var variables: [String]
        /// 1 for a number, 2 or 3 for a vector.
        var components: Int
        /// A numpy expression in a0, a1, a2 (a tuple for a vector).
        var code: String
    }

    /// A function the formula defines (`f(x) = …`) and later lines can use (`g(x) = f(x-1)`, `f'(x)`).
    struct Function: Equatable {
        var name: String
        var arity: Int
        var code: String
    }

    var items: [Item]
    var functions: [Function]
    /// Free letters in order of appearance; they become sliders.
    var parameters: [String]

    func isThreeD(style: PlotStyle?) -> Bool {
        items.contains { item in
            switch item.kind {
            case .surface: !(style?.isFlat ?? false)
            case .parametricSurface, .implicitSurface, .scalarField, .vectors3d: true
            case .parametric: item.components == 3
            default: false
            }
        }
    }

    /// Plane curves and space plots don't go into one picture.
    func validate(style: PlotStyle?) throws {
        guard isThreeD(style: style) else { return }
        let flat = items.contains { [.curve, .polar, .implicit, .region, .vectors].contains($0.kind) || ($0.kind == .parametric && $0.components == 2) }
        if flat {
            throw PlotError.notPlottable("Ebene Kurven und räumliche Plots passen nicht in ein Bild – schreib sie in zwei Formeln.")
        }
    }

    // What the plot settings offer.

    private static let planeKinds: [Kind] = [.implicit, .region, .surface, .vectors, .implicitSurface, .scalarField, .vectors3d]

    var curveVariable: String? { items.first { $0.kind == .curve }?.variables.first }
    var planeVariables: [String]? { items.first { Self.planeKinds.contains($0.kind) }?.variables }
    var spaceVariables: [String]? { items.first { [.implicitSurface, .scalarField, .vectors3d].contains($0.kind) }?.variables }
    var parameterVariable: String? { items.first { $0.kind == .polar || $0.kind == .parametric }?.variables.first }
    var surfaceParameters: [String]? { items.first { $0.kind == .parametricSurface }?.variables }
    var hasCurves: Bool { items.contains { $0.kind == .curve } }
    var hasSurfaces: Bool { items.contains { $0.kind == .surface } }
    var hasVectorField: Bool { items.contains { $0.kind == .vectors } }

    /// The axis names for matplotlib's mathtext.
    var axisLabels: [String] {
        if let variables = planeVariables {
            var names = variables.map { "$\($0)$" }
            if names.count < 3 { names.append(items.contains { $0.kind == .surface } ? "$z$" : "") }
            return names
        }
        if let variable = curveVariable { return ["$\(variable)$", "", "$z$"] }
        return ["$x$", "$y$", "$z$"]
    }

    /// A variable as plain text for the settings ("φ" for \varphi).
    static func displayName(_ token: String) -> String {
        let greek: [String: String] = [
            "\\varphi": "φ", "\\phi": "ϕ", "\\theta": "θ", "\\vartheta": "ϑ", "\\alpha": "α", "\\beta": "β", "\\gamma": "γ",
            "\\lambda": "λ", "\\mu": "μ", "\\omega": "ω", "\\rho": "ρ", "\\sigma": "σ", "\\tau": "τ", "\\psi": "ψ",
        ]
        return greek[token] ?? (token.hasPrefix("\\") ? String(token.dropFirst()) : token)
    }
}

/// Translates the formula tree into numpy code. Only what is understood gets through; everything else is an
/// error, so the generated code never contains text from the document.
///
/// What a line means follows how it is written: `f(x) = …` and `y = …` are curves, `f(x, y) = …` and `z = …` in x
/// and y are surfaces, `x^2 + y^2 = 1` is an implicit curve (with z a surface), `y \le …` a region, `r = …` in φ a
/// polar curve, `(\cos t, \sin t)` or `x = \cos t`, `y = \sin t` a curve in the plane or in space, `(u, v)` vectors
/// surfaces, and `(-y, x)` a vector field. Sums, products, integrals with bounds, piecewise functions (`cases`) and
/// functions defined in an earlier line (`f'(x)` too) can be part of any term.
enum PlotTranslator {
    static let cartesian = ["x", "y", "z"]
    static let angles = ["\\varphi", "\\phi", "\\theta", "\\vartheta"]
    /// The variable of a curve without `f(x)`, in order of preference.
    static let curveVariables = ["x", "t", "\\varphi", "\\phi", "\\theta", "\\vartheta", "s", "u", "z"]
    /// The parameter of a parametric curve.
    static let curveParameters = ["t", "s", "\\varphi", "\\phi", "\\theta", "\\vartheta", "u", "\\tau", "\\lambda"]
    static let surfaceParameters: [(String, String)] = [
        ("u", "v"), ("s", "t"), ("\\theta", "\\varphi"), ("\\vartheta", "\\varphi"), ("\\theta", "\\phi"), ("\\varphi", "\\theta"),
    ]
    static let relations: [String: String] = [
        "=": "=", "<": "<", ">": ">", "\\le": "<=", "\\leq": "<=", "\\leqslant": "<=", "\\ge": ">=", "\\geq": ">=", "\\geqslant": ">=",
    ]

    static func program(for latex: String) throws -> PlotProgram {
        let formula = MathFormula(latex: latex)
        var builder = Builder()
        for line in formula.lines where !line.isEmpty {
            let written = line.items.filter { $0.kind != .symbol("&") }
            let nodes = normalized(written)
            guard !nodes.isEmpty else { continue }
            let label = MathLaTeXWriter(caret: nil, placeholders: false).row(MathRow(written.map { $0.copy() }))
            try builder.add(nodes, label: label)
        }
        return try builder.finish()
    }

    // MARK: Lines

    private enum Form {
        case expression([MathNode])
        case equation(left: [MathNode], right: [MathNode])
        case inequality(pieces: [[MathNode]], operators: [String])
    }

    private static func form(of nodes: [MathNode]) throws -> Form {
        var pieces: [[MathNode]] = [[]]
        var operators: [String] = []
        for node in nodes {
            if case .symbol(let token) = node.kind, let relation = relations[token] {
                operators.append(relation)
                pieces.append([])
            } else {
                pieces[pieces.count - 1].append(node)
            }
        }
        guard !operators.isEmpty else { return .expression(nodes) }
        guard let right = pieces.last, !right.isEmpty else { throw PlotError.notPlottable("Die Formel ist unvollständig.") }
        if operators.allSatisfy({ $0 == "=" }) {
            // f(x) = … = …: the left of the first and the right of the last.
            return .equation(left: pieces[0], right: right)
        }
        guard !operators.contains("="), pieces.allSatisfy({ !$0.isEmpty }) else {
            throw PlotError.notPlottable("Gleichungen und Ungleichungen lassen sich nicht in einer Zeile mischen.")
        }
        return .inequality(pieces: pieces, operators: operators)
    }

    private struct Builder {
        var functions: [String: PlotProgram.Function] = [:]
        var functionList: [PlotProgram.Function] = []
        var items: [PlotProgram.Item] = []
        var parameters: [String] = []
        /// `x = \cos t`: one coordinate of a parametric curve or surface.
        struct Coordinate {
            var axis: String
            var variables: [String]
            var right: [MathNode]
            var label: String
        }
        var coordinates: [Coordinate] = []

        mutating func add(_ nodes: [MathNode], label: String) throws {
            switch try PlotTranslator.form(of: nodes) {
            case .inequality(let pieces, let operators):
                let letters = try pieces.flatMap { try collect($0) }
                guard !letters.contains("z") else { throw PlotError.notPlottable("Ungleichungen werden in der x-y-Ebene gezeichnet.") }
                var translator = makeTranslator(["x", "y"])
                var constraints: [String] = []
                for (index, relation) in operators.enumerated() {
                    let left = try translator.expression(pieces[index])
                    let right = try translator.expression(pieces[index + 1])
                    // Inside is where the value is ≤ 0.
                    constraints.append(relation.hasPrefix("<") ? "(\(left)) - (\(right))" : "(\(right)) - (\(left))")
                }
                let code = constraints.dropFirst().reduce(constraints[0]) { "np.maximum(\($0), \($1))" }
                append(.init(kind: .region, label: label, variables: ["x", "y"], components: 1, code: code), translator)
            case .expression(let right):
                try addFunction(name: nil, arguments: nil, bare: nil, right: right, label: label)
            case .equation(let left, let right):
                if let declaration = PlotTranslator.declaration(left) {
                    try addFunction(name: declaration.name, arguments: declaration.arguments, bare: nil, right: right, label: label)
                } else if let bare = PlotTranslator.letter(left) {
                    try addFunction(name: nil, arguments: nil, bare: bare, right: right, label: label)
                } else {
                    try addImplicit(left: left, right: right, label: label)
                }
            }
        }

        private mutating func addImplicit(left: [MathNode], right: [MathNode], label: String) throws {
            let letters = try collect(left) + collect(right)
            let variables = letters.contains("z") ? ["x", "y", "z"] : ["x", "y"]
            var translator = makeTranslator(variables)
            let code = "(\(try translator.expression(left))) - (\(try translator.expression(right)))"
            append(.init(kind: variables.count == 3 ? .implicitSurface : .implicit, label: label, variables: variables, components: 1, code: code), translator)
        }

        private mutating func addFunction(name: String?, arguments: [String]?, bare: String?, right: [MathNode], label: String) throws {
            let tuple = PlotTranslator.tuple(right)
            let letters = try (tuple ?? [right]).flatMap { try collect($0) }
            // y = x·y: the letter on the left is on the right too.
            if let bare, tuple == nil, letters.contains(bare) {
                return try addImplicit(left: [MathNode.symbol(bare)], right: right, label: label)
            }

            let variables: [String]
            let kind: PlotProgram.Kind
            if let tuple {
                guard (2...3).contains(tuple.count) else { throw PlotError.notPlottable("Ein Vektor braucht zwei oder drei Einträge.") }
                variables = arguments ?? PlotTranslator.vectorVariables(letters, count: tuple.count)
                switch (variables.count, tuple.count) {
                case (1, _): kind = .parametric
                case (2, 3): kind = .parametricSurface
                case (2, 2): kind = .vectors
                case (3, 3): kind = .vectors3d
                default: throw PlotError.notPlottable("Dieser Vektor lässt sich nicht zeichnen.")
                }
            } else if let arguments {
                variables = arguments
                switch arguments.count {
                case 1: kind = name == "r" && PlotTranslator.angles.contains(arguments[0]) ? .polar : .curve
                case 2: kind = .surface
                default: kind = .scalarField
                }
            } else if bare == "r", let angle = PlotTranslator.angles.first(where: letters.contains), !letters.contains("x"), !letters.contains("y") {
                variables = [angle]
                kind = .polar
            } else if let bare, PlotTranslator.cartesian.contains(bare), !letters.contains(where: PlotTranslator.cartesian.contains),
                      let parameters = PlotTranslator.coordinateParameters(letters) {
                // x = \cos t: waits for its y (and z).
                coordinates.append(Coordinate(axis: bare, variables: parameters, right: right, label: label))
                return
            } else {
                let present = PlotTranslator.cartesian.filter(letters.contains)
                if present.count == 3 {
                    variables = ["x", "y", "z"]
                    kind = .scalarField
                } else if present.contains("x"), present.contains("y") {
                    variables = ["x", "y"]
                    kind = .surface
                } else {
                    // `n!` on its own: drawn over its only letter.
                    let only = bare == nil && name == nil && letters.count == 1 ? letters.first : nil
                    variables = [PlotTranslator.curveVariables.first(where: letters.contains) ?? only ?? "x"]
                    kind = .curve
                }
            }

            var translator = makeTranslator(variables)
            let code: String
            if let tuple {
                code = "(" + (try tuple.map { try translator.expression($0) }).joined(separator: ", ") + ")"
            } else {
                code = try translator.expression(right)
            }
            append(.init(kind: kind, label: label, variables: variables, components: tuple?.count ?? 1, code: code), translator)
            if let name, tuple == nil, let arguments {
                let function = PlotProgram.Function(name: name, arity: arguments.count, code: code)
                functions[name] = function
                functionList.removeAll { $0.name == name }
                functionList.append(function)
            }
        }

        mutating func finish() throws -> PlotProgram {
            if !coordinates.isEmpty {
                let axes = coordinates.map(\.axis)
                guard Set(axes).count == axes.count else { throw PlotError.notPlottable("x, y und z dürfen je nur einmal festgelegt werden.") }
                let variables = coordinates.map(\.variables).max { $0.count < $1.count } ?? ["t"]
                if axes.count == 1 {
                    // Only y = f(t): a curve over t.
                    let coordinate = coordinates[0]
                    var translator = makeTranslator([variables[0]])
                    let code = try translator.expression(coordinate.right)
                    append(.init(kind: .curve, label: coordinate.label, variables: [variables[0]], components: 1, code: code), translator)
                } else {
                    guard axes.contains("x"), axes.contains("y") else {
                        throw PlotError.notPlottable("Für eine Kurve mit Parameter braucht es x = … und y = ….")
                    }
                    let ordered = PlotTranslator.cartesian.compactMap { axis in coordinates.first { $0.axis == axis } }
                    let kind: PlotProgram.Kind = variables.count == 2 ? .parametricSurface : .parametric
                    guard kind == .parametric || ordered.count == 3 else {
                        throw PlotError.notPlottable("Eine Fläche mit Parametern braucht x = …, y = … und z = ….")
                    }
                    var translator = makeTranslator(variables)
                    let code = "(" + (try ordered.map { try translator.expression($0.right) }).joined(separator: ", ") + ")"
                    append(.init(kind: kind, label: ordered.map(\.label).joined(separator: ",\\ "), variables: variables, components: ordered.count, code: code), translator)
                }
            }
            guard !items.isEmpty else { throw PlotError.notPlottable("Es gibt keinen Term, der von einer Variablen abhängt.") }
            return PlotProgram(items: items, functions: functionList, parameters: parameters)
        }

        /// The free letters of a term, in order (sum indices and integration variables don't count).
        private func collect(_ nodes: [MathNode]) throws -> [String] {
            var translator = Translator(variables: [:], functions: functions)
            _ = try translator.expression(nodes)
            return translator.letters
        }

        private func makeTranslator(_ variables: [String]) -> Translator {
            var names: [String: String] = [:]
            for (index, variable) in variables.enumerated() { names[variable] = "a\(index)" }
            return Translator(variables: names, functions: functions)
        }

        private mutating func append(_ item: PlotProgram.Item, _ translator: Translator) {
            items.append(item)
            for parameter in translator.parameters where !parameters.contains(parameter) { parameters.append(parameter) }
        }
    }

    // MARK: Reading the left side

    /// `f(x)`, `f(x, y)`, `f_1(x)`, `\vec{r}(t)`: the name (nil when it can't be called later) and the variables.
    static func declaration(_ left: [MathNode]) -> (name: String?, arguments: [String])? {
        guard left.count >= 2, let last = left.last, case .group(let open, _) = last.kind, open == "(" else { return nil }
        let head = Array(left.dropLast())
        var name: String?
        switch head.count {
        case 1:
            switch head[0].kind {
            case .symbol(let token) where isLetter(token): name = token
            case .accent, .style:
                guard head[0].slots.first?.items.count == 1, case .symbol(let token) = head[0].slots[0].items[0].kind, isLetter(token) else { return nil }
            default: return nil
            }
        case 2:
            guard case .symbol(let token) = head[0].kind, isLetter(token), let sub = head[1].subscript, head[1].superscript == nil,
                  let suffix = plainName(sub) else { return nil }
            name = token + "_" + suffix
        default:
            return nil
        }
        var arguments: [String] = []
        for argument in splitArguments(last.slots[0].items) {
            guard argument.count == 1, case .symbol(let token) = argument[0].kind, isLetter(token), token != "e" else { return nil }
            arguments.append(token)
        }
        guard (1...3).contains(arguments.count), Set(arguments).count == arguments.count else { return nil }
        return (name, arguments)
    }

    /// A single letter on its own: `y`, `z`, `r`.
    static func letter(_ nodes: [MathNode]) -> String? {
        guard nodes.count == 1, case .symbol(let token) = nodes[0].kind, isLetter(token) else { return nil }
        return token
    }

    /// The entries of a vector written as the whole right side: `(\cos t, \sin t)` or a one-column matrix.
    static func tuple(_ nodes: [MathNode]) -> [[MathNode]]? {
        guard nodes.count == 1 else { return nil }
        switch nodes[0].kind {
        case .group(let open, _) where open == "(" || open == "[" || open == "\\langle":
            let parts = splitArguments(nodes[0].slots[0].items)
            return parts.count >= 2 ? parts : nil
        case .matrix(let environment, let rows, let columns) where environment != "cases" && (rows == 1 || columns == 1) && rows * columns >= 2:
            return nodes[0].slots.map { normalized($0.items) }
        default:
            return nil
        }
    }

    /// The variables of a vector without `f(…)`: a surface's two parameters, a field's coordinates, or a curve's
    /// parameter.
    static func vectorVariables(_ letters: [String], count: Int) -> [String] {
        if count == 3, let pair = surfaceParameters.first(where: { letters.contains($0.0) && letters.contains($0.1) }) {
            return [pair.0, pair.1]
        }
        if letters.contains("x") || letters.contains("y") || letters.contains("z") {
            return count == 3 ? ["x", "y", "z"] : ["x", "y"]
        }
        return [curveParameters.first(where: letters.contains) ?? "t"]
    }

    /// The parameter(s) of a coordinate line `x = …`.
    static func coordinateParameters(_ letters: [String]) -> [String]? {
        if let pair = surfaceParameters.first(where: { letters.contains($0.0) && letters.contains($0.1) }) { return [pair.0, pair.1] }
        return curveParameters.first(where: letters.contains).map { [$0] }
    }

    // MARK: Helpers

    static func isLetter(_ token: String) -> Bool {
        (token.count == 1 && token.first!.isASCII && token.first!.isLetter) || MathSymbols.greek.contains(token)
    }

    /// Turns `(` … `)` and `[` … `]` written as single symbols into groups, the way the editor builds them, so
    /// both read the same.
    static func normalized(_ items: [MathNode]) -> [MathNode] {
        var result: [MathNode] = []
        var index = 0
        while index < items.count {
            let node = items[index]
            if case .symbol(let token) = node.kind, token == "(" || token == "[" {
                let close = token == "(" ? ")" : "]"
                var depth = 0
                var end: Int?
                for position in index..<items.count {
                    if items[position].kind == .symbol(token) { depth += 1 }
                    if items[position].kind == .symbol(close) {
                        depth -= 1
                        if depth == 0 { end = position; break }
                    }
                }
                if let end {
                    let inner = normalized(Array(items[(index + 1)..<end]))
                    result.append(MathNode(.group(left: token, right: close), slots: [MathRow(inner)]))
                    index = end + 1
                    continue
                }
            }
            result.append(MathNode(node.kind, slots: node.slots.map { MathRow(normalized($0.items)) }))
            index += 1
        }
        return result
    }

    /// Splits at the commas of this level; a comma between two digits is a decimal comma.
    static func splitArguments(_ items: [MathNode]) -> [[MathNode]] {
        var parts: [[MathNode]] = [[]]
        for (index, node) in items.enumerated() {
            if node.kind == .symbol(",") || node.kind == .symbol(";") {
                let between = index > 0 && index + 1 < items.count && isDigit(items[index - 1]) && isDigit(items[index + 1])
                if !between || node.kind == .symbol(";") {
                    parts.append([])
                    continue
                }
            }
            parts[parts.count - 1].append(node)
        }
        return parts.filter { !$0.isEmpty }
    }

    private static func isDigit(_ node: MathNode) -> Bool {
        if case .symbol(let token) = node.kind { return token.first?.isNumber == true }
        return false
    }

    /// A subscript as part of a name; only letters and digits.
    static func plainName(_ row: MathRow) -> String? {
        let text = row.items.map { node -> String in
            if case .symbol(let token) = node.kind { return token.hasPrefix("\\") ? String(token.dropFirst()) : token }
            return "?"
        }.joined()
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return text
    }

    /// The Python name of a parameter: only ASCII letters, digits and "_", so nothing from the document ends up as code.
    static func identifier(for parameter: String) -> String {
        "p_" + sanitized(parameter)
    }

    static func functionName(_ name: String) -> String {
        "u_" + sanitized(name)
    }

    private static func sanitized(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    // MARK: Terms

    private struct Translator {
        /// The plot's variables and their Python names (a0, a1, a2).
        let variables: [String: String]
        let functions: [String: PlotProgram.Function]
        /// Sum indices and integration variables while their term is read.
        var bound: [String: String] = [:]
        /// Free letters that aren't variables, in order.
        private(set) var parameters: [String] = []
        /// All free letters (variables too), in order.
        private(set) var letters: [String] = []

        init(variables: [String: String], functions: [String: PlotProgram.Function]) {
            self.variables = variables
            self.functions = functions
        }

        /// The array whose shape an integral's values take.
        private var reference: String { variables.values.sorted().first ?? "0.0" }

        private enum Piece {
            case operand(String)
            case operation(String)
        }

        static let numpyFunctions: [String: String] = [
            "\\sin": "np.sin", "\\cos": "np.cos", "\\tan": "np.tan", "\\arcsin": "np.arcsin", "\\arccos": "np.arccos",
            "\\arctan": "np.arctan", "\\sinh": "np.sinh", "\\cosh": "np.cosh", "\\tanh": "np.tanh", "\\ln": "np.log",
            "\\lg": "np.log10", "\\log": "np.log10", "\\exp": "np.exp", "\\operatorname{sgn}": "np.sign",
            "\\operatorname{sign}": "np.sign", "\\operatorname{abs}": "np.abs", "\\operatorname{arsinh}": "np.arcsinh",
            "\\operatorname{arcosh}": "np.arccosh", "\\operatorname{artanh}": "np.arctanh",
        ]
        static let reciprocal: [String: String] = ["\\cot": "np.tan", "\\sec": "np.cos", "\\csc": "np.sin", "\\coth": "np.tanh"]
        static let ignored: Set<String> = ["\\,", "\\;", "\\:", "\\!", "\\quad", "\\qquad", "&", "\\left.", "\\right."]
        static let comparisons: [String: String] = [
            "<": "<", ">": ">", "\\le": "<=", "\\leq": "<=", "\\leqslant": "<=", "\\ge": ">=", "\\geq": ">=", "\\geqslant": ">=",
            "=": "==", "\\neq": "!=", "\\ne": "!=",
        ]

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
                    case "!":
                        guard case .operand(let base) = pieces.last else { throw PlotError.notPlottable("Ein ! ohne Zahl davor.") }
                        pieces[pieces.count - 1] = .operand("_fact(\(base))")
                    case "'": throw PlotError.notPlottable("Ableitungen gehen mit einer Funktion aus einer Zeile davor, z. B. f'(x).")
                    case "\\infty": throw PlotError.notPlottable("∞ ist kein Wert.")
                    case "\\pi": operand("np.pi")
                    case "e" where bound["e"] == nil && variables["e"] == nil: operand("np.e")
                    default:
                        let isGreek = MathSymbols.greek.contains(token)
                        guard (token.count == 1 && token.first!.isLetter) || isGreek else {
                            throw PlotError.notPlottable("„\(token)“ kann nicht gerechnet werden.")
                        }
                        // A subscript is part of the name: a_1, f_2.
                        var name = token
                        var next = index + 1
                        var power: MathRow?
                        if next < items.count, let sub = items[next].subscript {
                            guard let suffix = PlotTranslator.plainName(sub) else { throw PlotError.notPlottable("Ein Index taugt nicht als Name.") }
                            name += "_" + suffix
                            power = items[next].superscript
                            next += 1
                        }
                        if let function = functions[name] {
                            operand(try call(function, items, from: &next))
                            index = next
                            continue
                        }
                        let resolved = resolve(name, isGreek: isGreek)
                        if let power {
                            operand("(\(resolved))**(" + (try expression(power.items)) + ")")
                        } else {
                            operand(resolved)
                        }
                        index = next
                        continue
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
                    if let function = Self.numpyFunctions[name] {
                        call = "\(function)(\(argument))"
                        if name == "\\log", let base { call = "(np.log(\(argument))/np.log(\(base)))" }
                    } else if let function = Self.reciprocal[name] {
                        call = "(1/\(function)(\(argument)))"
                    } else {
                        throw PlotError.notPlottable("„\(name)“ wird noch nicht gezeichnet.")
                    }
                    if let power { call = "(\(call))**(\(power))" }
                    operand(call)
                case .largeOperator(let name):
                    switch name {
                    case "\\sum", "\\prod":
                        operand(try bigOperator(name == "\\sum" ? "_sum" : "_prod", items, at: &index))
                        continue
                    case "\\int":
                        operand(try integral(items, at: &index))
                        continue
                    case "\\max", "\\min":
                        guard index + 1 < items.count, case .group = items[index + 1].kind else {
                            throw PlotError.notPlottable("max und min brauchen ihre Werte in Klammern: \\max(a, b).")
                        }
                        let values = try PlotTranslator.splitArguments(items[index + 1].slots[0].items).map { try expression($0) }
                        guard values.count >= 2 else { throw PlotError.notPlottable("max und min brauchen mindestens zwei Werte.") }
                        let function = name == "\\max" ? "np.maximum" : "np.minimum"
                        operand(values.dropFirst().reduce(values[0]) { "\(function)(\($0), \($1))" })
                        index += 1
                    default:
                        throw PlotError.notPlottable("Grenzwerte und Mehrfachintegrale werden noch nicht gezeichnet.")
                    }
                case .fraction:
                    operand("((" + (try expression(node.slots[0].items)) + ")/(" + (try expression(node.slots[1].items)) + "))")
                case .binomial:
                    operand("_binom(" + (try expression(node.slots[0].items)) + ", " + (try expression(node.slots[1].items)) + ")")
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
                    if PlotTranslator.splitArguments(node.slots[0].items).count > 1, left == "(" || left == "[" {
                        throw PlotError.notPlottable("Ein Vektor lässt sich nur als ganze rechte Seite zeichnen.")
                    }
                    let inner = try expression(node.slots[0].items)
                    switch left {
                    case "|", "\\|", "\\vert", "\\Vert", "\\lvert": operand("np.abs(\(inner))")
                    case "\\lfloor": operand("np.floor(\(inner))")
                    case "\\lceil": operand("np.ceil(\(inner))")
                    default: operand("(\(inner))")
                    }
                case .matrix(let environment, let rows, let columns) where environment == "cases":
                    operand(try cases(node, rows: rows, columns: columns))
                case .style(let name) where ["\\mathrm", "\\text", "\\textrm"].contains(name) && node.slots[0].items.count == 1 && node.slots[0].items[0].kind == .symbol("e"):
                    operand("np.e")
                case .accent, .style, .text, .matrix, .raw:
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

        /// A letter that isn't a function: a bound index, a variable or a parameter.
        private mutating func resolve(_ name: String, isGreek: Bool) -> String {
            if let bound = bound[name] { return bound }
            if !letters.contains(name) { letters.append(name) }
            if let variable = variables[name] { return variable }
            // Parameters are named without the backslash: "alpha", "a_1".
            let parameter = isGreek ? String(name.dropFirst()) : name
            if !parameters.contains(parameter) { parameters.append(parameter) }
            return PlotTranslator.identifier(for: parameter)
        }

        /// `f(x - 1)`, `f'(x)`, `g(x, 2)` for a function from an earlier line.
        private mutating func call(_ function: PlotProgram.Function, _ items: [MathNode], from next: inout Int) throws -> String {
            var primes = 0
            while next < items.count, items[next].kind == .symbol("'") {
                primes += 1
                next += 1
            }
            if next < items.count, let sup = items[next].superscript, items[next].subscript == nil,
               !sup.items.isEmpty, sup.items.allSatisfy({ $0.kind == .symbol("\\prime") || $0.kind == .symbol("'") }) {
                primes += sup.items.count
                next += 1
            }
            guard next < items.count, case .group(let open, _) = items[next].kind, open == "(" else {
                throw PlotError.notPlottable("„\(function.name)“ braucht ein Argument, z. B. \(function.name)(x).")
            }
            guard primes <= 3 else { throw PlotError.notPlottable("Mehr als drei Ableitungen werden nicht gezeichnet.") }
            let arguments = try PlotTranslator.splitArguments(items[next].slots[0].items).map { try expression($0) }
            guard arguments.count == function.arity else {
                throw PlotError.notPlottable("„\(function.name)“ hat \(function.arity) Variable\(function.arity == 1 ? "" : "n").")
            }
            guard primes == 0 || function.arity == 1 else { throw PlotError.notPlottable("Ableitungen gehen nur bei Funktionen einer Variablen.") }
            next += 1
            var callee = PlotTranslator.functionName(function.name)
            for _ in 0..<primes { callee = "_d(\(callee))" }
            return "\(callee)(\(arguments.joined(separator: ", ")))"
        }

        /// `\sum_{k=1}^{n} …` or `\prod`: the term runs to the next + or −.
        private mutating func bigOperator(_ helper: String, _ items: [MathNode], at index: inout Int) throws -> String {
            guard index + 1 < items.count, let sub = items[index + 1].subscript, let sup = items[index + 1].superscript else {
                throw PlotError.notPlottable("Summen und Produkte brauchen Grenzen, z. B. k = 1 bis n.")
            }
            let lowerItems = sub.items
            guard lowerItems.count >= 3, case .symbol(let variable) = lowerItems[0].kind, PlotTranslator.isLetter(variable),
                  lowerItems[1].kind == .symbol("=") else {
                throw PlotError.notPlottable("Unter dem Summenzeichen steht der Laufindex mit Start, z. B. k = 1.")
            }
            let lower = try expression(Array(lowerItems[2...]))
            let upper = try expression(sup.items)
            var end = index + 2
            while end < items.count {
                if case .symbol(let token) = items[end].kind, token == "+" || token == "-" { break }
                end += 1
            }
            guard end > index + 2 else { throw PlotError.notPlottable("Der Summe fehlt ihr Term.") }
            let name = "b_" + PlotTranslator.sanitized(variable)
            let saved = bound[variable]
            bound[variable] = name
            defer { bound[variable] = saved }
            let term = try expression(Array(items[(index + 2)..<end]))
            index = end
            return "\(helper)(lambda \(name): (\(term)), \(lower), \(upper))"
        }

        /// `\int_a^b … dt`: computed numerically; the bounds may depend on the variables (`\int_0^x`).
        private mutating func integral(_ items: [MathNode], at index: inout Int) throws -> String {
            guard index + 1 < items.count, let sub = items[index + 1].subscript, let sup = items[index + 1].superscript else {
                throw PlotError.notPlottable("Ein Integral braucht Grenzen, z. B. von 0 bis x.")
            }
            let lower = try expression(sub.items)
            let upper = try expression(sup.items)
            var position = index + 2
            var differential: (index: Int, variable: String)?
            while position + 1 < items.count {
                if Self.isDifferential(items[position]), case .symbol(let variable) = items[position + 1].kind, PlotTranslator.isLetter(variable) {
                    differential = (position, variable)
                    break
                }
                position += 1
            }
            guard let differential else { throw PlotError.notPlottable("Am Ende des Integrals fehlt das d mit der Variablen, z. B. dt.") }
            let term = items[(index + 2)..<differential.index].filter { node in
                if case .symbol(let token) = node.kind { return !Self.ignored.contains(token) }
                return true
            }
            guard !term.isEmpty else { throw PlotError.notPlottable("Dem Integral fehlt sein Term.") }
            let name = "b_" + PlotTranslator.sanitized(differential.variable)
            let saved = bound[differential.variable]
            bound[differential.variable] = name
            defer { bound[differential.variable] = saved }
            let integrand = try expression(Array(term))
            index = differential.index + 2
            return "_int(lambda \(name): (\(integrand)), \(lower), \(upper), \(reference))"
        }

        private static func isDifferential(_ node: MathNode) -> Bool {
            switch node.kind {
            case .symbol(let token): return token == "d"
            case .style, .text: return node.slots.first?.items.count == 1 && node.slots[0].items[0].kind == .symbol("d")
            case .function(let name): return name == "\\operatorname{d}"
            default: return false
            }
        }

        /// A piecewise function: each row a value and its condition (`x < 0`, `0 \le x < 1`, `\text{sonst}`).
        private mutating func cases(_ node: MathNode, rows: Int, columns: Int) throws -> String {
            var pairs: [String] = []
            for row in 0..<rows {
                let value = node.slots[row * columns].items.filter { $0.kind != .symbol(",") }
                let condition = columns > 1 ? node.slots[row * columns + 1].items : []
                guard !value.isEmpty else { continue }
                pairs.append("((\(try self.condition(condition))), (\(try expression(value))))")
            }
            guard !pairs.isEmpty else { throw PlotError.notPlottable("Die Fallunterscheidung ist leer.") }
            return "_cases([\(pairs.joined(separator: ", "))], \(reference))"
        }

        /// `x < 0`, `0 \le x < 1`; words (`\text{für}`, `\text{sonst}`) are left out, no comparison means "otherwise".
        private mutating func condition(_ items: [MathNode]) throws -> String {
            let items = items.filter { node in
                switch node.kind {
                case .text: return false
                case .symbol(let token): return token != "," && !Self.ignored.contains(token)
                default: return true
                }
            }
            guard !items.isEmpty else { return "True" }
            var pieces: [[MathNode]] = [[]]
            var operators: [String] = []
            for node in items {
                if case .symbol(let token) = node.kind, let comparison = Self.comparisons[token] {
                    operators.append(comparison)
                    pieces.append([])
                } else {
                    pieces[pieces.count - 1].append(node)
                }
            }
            guard !operators.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
                throw PlotError.notPlottable("Bedingungen schreiben sich wie x < 0 oder 0 \\le x < 1.")
            }
            let terms = try pieces.map { try expression($0) }
            return operators.indices.map { "((\(terms[$0])) \(operators[$0]) (\(terms[$0 + 1])))" }.joined(separator: " & ")
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
    }
}
