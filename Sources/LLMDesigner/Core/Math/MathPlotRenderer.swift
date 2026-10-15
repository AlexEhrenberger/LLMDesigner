import Foundation

/// Runs Python with numpy and matplotlib to draw a plot: a light PNG for paper, a dark one for the dark sheet,
/// and a PDF for LaTeX. A quick render (while the view is turned) draws only a small dark PNG.
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

    func render(_ program: PlotProgram, spec: PlotSpec, quick: Bool = false) async throws -> Output {
        try program.validate(style: spec.style)
        guard let python = await pythonExecutable() else { throw PlotError.noPython }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesigner-Plot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("plot.py")
        let config = directory.appendingPathComponent("config.json")
        try Self.script(for: program).write(to: script, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: Self.configuration(program, spec, quick: quick)).write(to: config)
        do {
            _ = try await run(python, ["-I", script.path, config.path, directory.path], timeout: 60)
        } catch PlotError.failed(let log) where log.contains("NOVALUES") {
            throw PlotError.noValues
        } catch PlotError.failed(let log) where log.contains("SUMLIMIT") {
            throw PlotError.notPlottable("Die Summe hat mehr als 20 000 Glieder.")
        } catch PlotError.failed(let log) where log.contains("BOUNDS") {
            throw PlotError.notPlottable("Die Grenzen einer Summe müssen Zahlen sein, keine Variablen.")
        }
        let output = Output(directory: directory)
        guard FileManager.default.fileExists(atPath: (quick ? output.dark : output.light).path) else { throw PlotError.failed("") }
        return output
    }

    private static func configuration(_ program: PlotProgram, _ spec: PlotSpec, quick: Bool) -> [String: Any] {
        var parameters: [String: Double] = [:]
        for name in program.parameters { parameters[PlotTranslator.identifier(for: name)] = spec.parameters[name] ?? 1 }
        let threeD = program.isThreeD(style: spec.style)
        let style = spec.style ?? (program.hasVectorField && !program.hasSurfaces ? .streamlines : .surface)
        func range(_ range: PlotRange?) -> Any { range.map { $0.values as Any } ?? NSNull() }
        return [
            "params": parameters,
            "items": program.items.map { item -> [String: Any] in
                let kind = item.kind == .surface && style.isFlat ? "field" : item.kind.rawValue
                return ["kind": kind, "label": item.label]
            },
            "ranges": ["x": spec.x.values, "y": range(spec.y), "z": range(spec.z), "t": range(spec.t), "u": range(spec.u), "v": range(spec.v)],
            "mode": threeD ? "3d" : "2d",
            "style": style.rawValue,
            "view": [spec.elevation, spec.azimuth],
            "grid": spec.grid,
            "marks": spec.marks,
            "quick": quick,
            "decimalComma": true,
            // matplotlib's mathtext drops the delimiters of \left( … \right); plain ones read the same in a legend.
            "labels": program.items.map { Self.mathtext($0.kind == .scalarField ? Self.leftSide($0.label) : $0.label) },
            "plainLabels": program.items.indices.map { program.items.count == 1 ? "" : "Graph \($0 + 1)" },
            "axisLabels": program.axisLabels,
            "themes": [
                "light": ["background": "#FFFFFF", "text": "#1C1C1F", "axis": "#8A8A92", "grid": "#E6E6EC", "pane": "#F6F6F9",
                          "contour": "#FFFFFF80", "ramp": ["#2B1D7A", "#6A54E0", "#E0546A", "#F2B14C"],
                          "colors": ["#6A54E0", "#E0546A", "#1F9D57", "#D98A00", "#2B7FD9", "#B04CC9"]],
                "dark": ["background": "#141417", "text": "#E8E8EC", "axis": "#7A7A84", "grid": "#2A2A31", "pane": "#1B1B20",
                         "contour": "#00000060", "ramp": ["#3A2C91", "#7E68F0", "#FF8FA3", "#FFD27A"],
                         "colors": ["#A996FF", "#FF8FA3", "#5FD38A", "#F2B14C", "#6FD3FF", "#E29BFF"]],
            ],
        ]
    }

    /// LaTeX that matplotlib's mathtext can set: it drops the delimiters of \\left( … \\right) and knows only
    /// some spellings.
    static func mathtext(_ latex: String) -> String {
        var text = latex.replacingOccurrences(of: #"\\(left|right)(?![A-Za-z])\.?"#, with: "", options: .regularExpression)
        for (pattern, replacement) in [
            (#"\\le(qslant)?(?![A-Za-z])"#, #"\\leq"#), (#"\\ge(qslant)?(?![A-Za-z])"#, #"\\geq"#), (#"\\[dt]frac"#, #"\\frac"#),
            (#"\\operatorname\{([A-Za-z]+)\}"#, #"\\mathrm{$1}"#),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// `f(x, y, z) = …` → `f(x, y, z)`: the level surfaces carry their value in the legend.
    static func leftSide(_ label: String) -> String {
        guard let equals = label.range(of: "=") else { return "f" }
        return String(label[..<equals.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The fixed drawing script with the formula's functions in it. The functions only hold code the translator
    /// built from whitelisted tokens.
    static func script(for program: PlotProgram) -> String {
        var parts: [String] = program.parameters.map {
            let name = PlotTranslator.identifier(for: $0)
            return "\(name) = float(P[\"\(name)\"])"
        }
        for function in program.functions {
            let arguments = (0..<function.arity).map { "a\($0)" }.joined(separator: ", ")
            parts.append("def \(PlotTranslator.functionName(function.name))(\(arguments)):\n    return \(function.code)")
        }
        for (index, item) in program.items.enumerated() {
            let arguments = item.variables.indices.map { "a\($0)" }.joined(separator: ", ")
            parts.append("def g\(index)(\(arguments)):\n    return \(item.code)")
        }
        return template.replacingOccurrences(of: "#__GENERATED__", with: parts.joined(separator: "\n\n"))
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

    /// The drawing script. It reads the configuration (ranges, style, view, colours) from the JSON file given as
    /// its first argument and writes into the folder given as the second.
    private static let template = #"""
import json, sys, math, warnings, locale
warnings.filterwarnings("ignore")
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, Normalize
from matplotlib.patches import Patch
from matplotlib.ticker import MaxNLocator
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
OUT = sys.argv[2]
P = cfg["params"]
TAU = 2 * np.pi
COMMA = False
if cfg.get("decimalComma"):
    try:
        locale.setlocale(locale.LC_NUMERIC, "de_DE.UTF-8")
        plt.rcParams["axes.formatter.use_locale"] = True
        COMMA = True
    except Exception:
        pass


def number(value):
    text = "%.3g" % value
    if text in ("-0", "-0.0"):
        text = "0"
    text = text.replace("-", "\u2212")
    return text.replace(".", ",") if COMMA else text


def _fact(n):
    def one(v):
        if v < 0 and v == math.floor(v):
            return np.nan
        return math.gamma(v + 1.0) if v < 171 else np.inf
    return np.vectorize(one, otypes=[float])(np.asarray(n, dtype=float))


def _binom(n, k):
    return _fact(n) / (_fact(k) * _fact(np.asarray(n, dtype=float) - np.asarray(k, dtype=float)))


def _bound(value):
    value = np.asarray(value, dtype=float)
    if value.size != 1:
        raise ValueError("BOUNDS")
    return int(round(float(value.reshape(-1)[0])))


def _sum(fn, lo, hi):
    lo, hi = _bound(lo), _bound(hi)
    if hi - lo > 20000:
        raise ValueError("SUMLIMIT")
    total = 0.0
    for k in range(lo, hi + 1):
        total = total + fn(float(k))
    return total


def _prod(fn, lo, hi):
    lo, hi = _bound(lo), _bound(hi)
    if hi - lo > 20000:
        raise ValueError("SUMLIMIT")
    total = 1.0
    for k in range(lo, hi + 1):
        total = total * fn(float(k))
    return total


def _int(fn, lo, hi, like, n=241):
    lo = np.asarray(lo, dtype=float)
    hi = np.asarray(hi, dtype=float)
    shape = np.broadcast(lo, hi, np.asarray(like)).shape
    s = np.linspace(0.0, 1.0, n).reshape((n,) + (1,) * len(shape))
    T = lo + (hi - lo) * s
    values = np.asarray(fn(T), dtype=float) * np.ones_like(T)
    return np.trapezoid(values, dx=1.0 / (n - 1), axis=0) * (hi - lo)


def _d(fn):
    def derivative(*args):
        x = np.asarray(args[0], dtype=float)
        h = 1e-4 * np.maximum(1.0, np.abs(x))
        return (fn(x + h, *args[1:]) - fn(x - h, *args[1:])) / (2 * h)
    return derivative


def _cases(pairs, like):
    result = np.full(np.shape(np.asarray(like, dtype=float)), np.nan)
    done = np.zeros(result.shape, dtype=bool)
    for condition, value in pairs:
        condition = np.asarray(condition, dtype=bool) & ~done
        value = np.asarray(value, dtype=float) * np.ones(result.shape)
        result = np.where(condition, value, result)
        done = done | condition
    return result


#__GENERATED__


ITEMS = cfg["items"]
FUNCS = [globals()["g%d" % i] for i in range(len(ITEMS))]
R = cfg["ranges"]
MODE = cfg["mode"]
STYLE = cfg["style"]


def rng(name, fallback):
    value = R.get(name)
    return value if value else fallback


def clean(value, like):
    v = np.asarray(value)
    if np.iscomplexobj(v):
        v = np.where(np.abs(v.imag) < 1e-12, v.real, np.nan)
    v = np.asarray(v, dtype=float) * np.ones(np.shape(like))
    v[~np.isfinite(v)] = np.nan
    return v


def call(fn, *args):
    with np.errstate(all="ignore"):
        result = fn(*args)
    if isinstance(result, tuple):
        return [clean(component, args[0]) for component in result]
    return clean(result, args[0])


def auto_range(arrays, fixed):
    if fixed:
        return fixed[0], fixed[1]
    finite = [a[np.isfinite(a)] for a in arrays]
    finite = [a for a in finite if a.size]
    if not finite:
        return None
    vals = np.concatenate(finite)
    lo, hi = float(np.min(vals)), float(np.max(vals))
    p_lo, p_hi = np.percentile(vals, [3, 97])
    if (hi - lo) > 6 * max(p_hi - p_lo, 1e-12):
        lo, hi = float(p_lo), float(p_hi)
    if hi - lo < 1e-9:
        lo, hi = lo - 1, hi + 1
    pad = (hi - lo) * 0.06
    return lo - pad, hi + pad


# ---------- Isosurfaces (marching tetrahedra) ----------

CORNERS = np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]])
TETS = np.array([[0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6], [0, 5, 1, 6]])


def isosurface(F, xs, ys, zs, level=0.0):
    nx, ny, nz = F.shape
    I, J, K = np.meshgrid(np.arange(nx - 1), np.arange(ny - 1), np.arange(nz - 1), indexing="ij")
    I, J, K = I.ravel(), J.ravel(), K.ravel()
    triangles = []
    for tet in TETS:
        offsets = CORNERS[tet]
        Pi = I[:, None] + offsets[None, :, 0]
        Pj = J[:, None] + offsets[None, :, 1]
        Pk = K[:, None] + offsets[None, :, 2]
        V = F[Pi, Pj, Pk] - level
        points = np.stack([xs[Pi], ys[Pj], zs[Pk]], axis=-1)
        valid = np.all(np.isfinite(V), axis=1)
        code = ((V < 0) * (1 << np.arange(4))).sum(axis=1)
        for case in range(1, 15):
            chosen = valid & (code == case)
            if not chosen.any():
                continue
            inside = [b for b in range(4) if case >> b & 1]
            outside = [b for b in range(4) if not case >> b & 1]
            Vs, Ps = V[chosen], points[chosen]

            def edge(a, b):
                va, vb = Vs[:, a][:, None], Vs[:, b][:, None]
                t = va / (va - vb)
                return Ps[:, a] + t * (Ps[:, b] - Ps[:, a])

            if len(inside) == 1 or len(outside) == 1:
                lone = inside[0] if len(inside) == 1 else outside[0]
                others = [b for b in range(4) if b != lone]
                triangles.append(np.stack([edge(lone, o) for o in others], axis=1))
            else:
                a, b = inside
                c, d = outside
                p1, p2, p3, p4 = edge(a, c), edge(a, d), edge(b, d), edge(b, c)
                triangles.append(np.stack([p1, p2, p3], axis=1))
                triangles.append(np.stack([p1, p3, p4], axis=1))
    return np.concatenate(triangles) if triangles else np.zeros((0, 3, 3))


def shade(triangles, base, alpha=1.0):
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    length = np.linalg.norm(normals, axis=1)
    length[length == 0] = 1
    normals = normals / length[:, None]
    light = np.array([-0.45, -0.55, 0.7])
    light = light / np.linalg.norm(light)
    intensity = 0.38 + 0.62 * np.abs(normals @ light)
    rgb = np.array(matplotlib.colors.to_rgb(base))
    colors = np.clip(rgb[None, :] * intensity[:, None] + 0.08 * (1 - intensity[:, None]), 0, 1)
    return np.concatenate([colors, np.full((len(colors), 1), alpha)], axis=1)


# ---------- Data ----------

X_RANGE = rng("x", [-5, 5])
Y_RANGE = rng("y", None)
Z_RANGE = rng("z", None)
T_RANGE = rng("t", [0, TAU])
U_RANGE = rng("u", [0, TAU])
V_RANGE = rng("v", [0, TAU])
QUICK = cfg.get("quick", False)

data = []
for item, fn in zip(ITEMS, FUNCS):
    kind = item["kind"]
    if kind == "curve":
        x = np.linspace(X_RANGE[0], X_RANGE[1], 2001)
        data.append((kind, x, call(fn, x)))
    elif kind in ("polar", "parametric"):
        t = np.linspace(T_RANGE[0], T_RANGE[1], 3001)
        values = call(fn, t)
        if kind == "polar":
            data.append(("line", values * np.cos(t), values * np.sin(t)))
        elif len(values) == 2:
            data.append(("line", values[0], values[1]))
        else:
            data.append(("line3d", values[0], values[1], values[2]))
    elif kind in ("implicit", "region", "field", "vectors"):
        y_range = Y_RANGE or X_RANGE
        n = 26 if kind == "vectors" and STYLE == "arrows" else (220 if kind == "vectors" else (180 if QUICK else 420))
        xs = np.linspace(X_RANGE[0], X_RANGE[1], n)
        ys = np.linspace(y_range[0], y_range[1], n)
        Xg, Yg = np.meshgrid(xs, ys)
        values = call(fn, Xg, Yg)
        data.append((kind, Xg, Yg, values))
    elif kind == "surface":
        y_range = Y_RANGE or X_RANGE
        n = 46 if QUICK else 84
        xs = np.linspace(X_RANGE[0], X_RANGE[1], n)
        ys = np.linspace(y_range[0], y_range[1], n)
        Xg, Yg = np.meshgrid(xs, ys)
        data.append((kind, Xg, Yg, call(fn, Xg, Yg)))
    elif kind == "parametricSurface":
        n = 46 if QUICK else 84
        us = np.linspace(U_RANGE[0], U_RANGE[1], n)
        vs = np.linspace(V_RANGE[0], V_RANGE[1], n)
        Ug, Vg = np.meshgrid(us, vs)
        data.append((kind,) + tuple(call(fn, Ug, Vg)))
    elif kind in ("implicitSurface", "scalarField"):
        n = 26 if QUICK else 38
        y_range = Y_RANGE or X_RANGE
        z_range = Z_RANGE or X_RANGE
        xs = np.linspace(X_RANGE[0], X_RANGE[1], n)
        ys = np.linspace(y_range[0], y_range[1], n)
        zs = np.linspace(z_range[0], z_range[1], n)
        Xg, Yg, Zg = np.meshgrid(xs, ys, zs, indexing="ij")
        F = call(fn, Xg, Yg, Zg)
        if kind == "implicitSurface":
            data.append((kind, [isosurface(F, xs, ys, zs, 0.0)], [None]))
        else:
            finite = F[np.isfinite(F)]
            levels = list(np.percentile(finite, [6, 22, 45])) if finite.size else []
            data.append((kind, [isosurface(F, xs, ys, zs, level) for level in levels], levels))
    elif kind == "vectors3d":
        n = 6 if QUICK else 7
        y_range = Y_RANGE or X_RANGE
        z_range = Z_RANGE or X_RANGE
        xs = np.linspace(X_RANGE[0], X_RANGE[1], n)
        ys = np.linspace(y_range[0], y_range[1], n)
        zs = np.linspace(z_range[0], z_range[1], n)
        Xg, Yg, Zg = np.meshgrid(xs, ys, zs, indexing="ij")
        data.append((kind, Xg, Yg, Zg, call(fn, Xg, Yg, Zg)))


def has_values(entry):
    kind = entry[0]
    if kind in ("implicitSurface", "scalarField"):
        return any(len(t) for t in entry[1])
    arrays = entry[1:]
    flat = []
    for a in arrays:
        if isinstance(a, list):
            flat.extend(a)
        else:
            flat.append(a)
    last = flat[-1]
    return np.isfinite(np.asarray(last, dtype=float)).any()


if not data or not any(has_values(entry) for entry in data):
    print("NOVALUES", file=sys.stderr)
    sys.exit(3)

# Value range of explicit curves; steep jumps (poles) are cut.
curve_values = [entry[2] for entry in data if entry[0] == "curve"]
line_x = [entry[1] for entry in data if entry[0] == "line"]
line_y = [entry[2] for entry in data if entry[0] == "line"]
Y_FIXED = Y_RANGE if any(entry[0] == "curve" for entry in data) else None
value_range = auto_range(curve_values + line_y, Y_FIXED) if (curve_values or line_y) else None
if value_range:
    span = value_range[1] - value_range[0]
    for y in curve_values:
        with np.errstate(all="ignore"):
            jumps = np.abs(np.diff(y)) > span * 0.5
        y[1:][jumps] = np.nan

# Marks: zeros and extrema of explicit curves.
marks = []
if cfg.get("marks"):
    for entry in data:
        if entry[0] != "curve":
            continue
        x, y = entry[1], entry[2]
        found = []
        s = np.sign(y)
        for i in np.where((s[:-1] * s[1:] < 0) & np.isfinite(y[:-1]) & np.isfinite(y[1:]))[0]:
            x0 = x[i] - y[i] * (x[i + 1] - x[i]) / (y[i + 1] - y[i])
            found.append((x0, 0.0, "zero"))
        for i in np.where(y == 0)[0]:
            found.append((x[i], 0.0, "zero"))
        dy = np.diff(y)
        ds = np.sign(dy)
        for i in np.where((ds[:-1] * ds[1:] < 0) & np.isfinite(dy[:-1]) & np.isfinite(dy[1:]))[0]:
            found.append((x[i + 1], y[i + 1], "max" if ds[i] > 0 else "min"))
        if len(found) <= 24:
            marks.extend(found)


# ---------- Drawing ----------

def colormap(t):
    return LinearSegmentedColormap.from_list("llmd", t["ramp"])


def style_axes_2d(ax, t):
    for spine in ax.spines.values():
        spine.set_color(t["axis"])
    ax.tick_params(colors=t["text"])
    if cfg["grid"] and not any(entry[0] == "field" for entry in data):
        ax.grid(True, color=t["grid"], lw=0.7, zorder=0)


def style_axes_3d(ax, t):
    pane = matplotlib.colors.to_rgba(t["pane"])
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        axis.set_pane_color(pane)
        axis.line.set_color(t["axis"])
        axis.label.set_color(t["text"])
        axis._axinfo["grid"]["color"] = matplotlib.colors.to_rgba(t["grid"])
        axis._axinfo["grid"]["linewidth"] = 0.6
        axis._axinfo["tick"]["color"] = t["axis"]
        axis.set_major_locator(MaxNLocator(nbins=6))
    ax.tick_params(colors=t["text"], labelsize=8)
    ax.grid(bool(cfg["grid"]))


def draw(theme, path, labels, dpi):
    t = cfg["themes"][theme]
    cmap = colormap(t)
    colors = t["colors"]
    plt.rcParams.update({"font.size": 10, "mathtext.fontset": "cm", "axes.unicode_minus": True})
    handles = []
    if MODE == "3d":
        fig = plt.figure(figsize=(6.4, 4.8))
        ax = fig.add_subplot(projection="3d", computed_zorder=False)
    else:
        fig, ax = plt.subplots(figsize=(6.4, 4.0))
    fig.patch.set_facecolor(t["background"])
    ax.set_facecolor(t["background"])
    colorbar_source = None

    if MODE == "3d":
        style_axes_3d(ax, t)
        zs_all = [entry[3] for entry in data if entry[0] == "surface"]
        z_range = auto_range(zs_all, Z_RANGE) if zs_all else None
        for i, entry in enumerate(data):
            color = colors[i % len(colors)]
            kind = entry[0]
            label = labels[i] or None
            if kind == "surface":
                Xg, Yg, Zg = entry[1], entry[2], entry[3].copy()
                if z_range:
                    Zg[(Zg < z_range[0]) | (Zg > z_range[1])] = np.nan
                if STYLE == "wireframe":
                    ax.plot_wireframe(Xg, Yg, Zg, rstride=3, cstride=3, color=color, lw=0.6)
                elif len(zs_all) > 1:
                    ax.plot_surface(Xg, Yg, Zg, color=color, alpha=0.78, linewidth=0, antialiased=True, shade=True, rasterized=True)
                else:
                    norm = Normalize(*(z_range or (np.nanmin(Zg), np.nanmax(Zg))))
                    colorbar_source = ax.plot_surface(Xg, Yg, Zg, cmap=cmap, norm=norm, linewidth=0, antialiased=True, rstride=1, cstride=1, alpha=0.96, rasterized=True)
                handles.append(Patch(color=color, label=label))
            elif kind == "parametricSurface":
                Xs, Ys, Zs = entry[1], entry[2], entry[3]
                finite = np.isfinite(Zs)
                lo, hi = (np.nanmin(Zs), np.nanmax(Zs)) if finite.any() else (0, 1)
                faces = cmap(Normalize(lo, hi if hi > lo else lo + 1)(np.nan_to_num(Zs, nan=lo)))
                ax.plot_surface(Xs, Ys, Zs, facecolors=faces, linewidth=0, antialiased=True, rstride=1, cstride=1, shade=True, alpha=0.96, rasterized=True)
                handles.append(Patch(color=color, label=label))
            elif kind in ("implicitSurface", "scalarField"):
                surfaces, levels = entry[1], entry[2]
                for j, (triangles, level) in enumerate(zip(surfaces, levels)):
                    if not len(triangles):
                        continue
                    base = color if kind == "implicitSurface" else cmap(0.15 + 0.7 * j / max(1, len(surfaces) - 1))
                    alpha = 1.0 if kind == "implicitSurface" else [0.75, 0.42, 0.22][j % 3]
                    collection = Poly3DCollection(triangles, facecolors=shade(triangles, base, alpha), edgecolors="none")
                    collection.set_rasterized(True)
                    ax.add_collection3d(collection)
                    if kind == "scalarField":
                        handles.append(Patch(color=base, label="%s = %s" % (labels[i] or "f", number(level))))
                if kind == "implicitSurface":
                    handles.append(Patch(color=color, label=label))
            elif kind == "line3d":
                ax.plot(entry[1], entry[2], entry[3], color=color, lw=2.0, label=label)
                handles.append(matplotlib.lines.Line2D([], [], color=color, lw=2.0, label=label))
            elif kind == "vectors3d":
                Xg, Yg, Zg, (U, V, W) = entry[1], entry[2], entry[3], entry[4]
                step = (X_RANGE[1] - X_RANGE[0]) / 9
                ax.quiver(Xg, Yg, Zg, U, V, W, length=step, normalize=True, color=color, lw=0.9, arrow_length_ratio=0.35)
                handles.append(Patch(color=color, label=label))
        has_grid_kinds = any(entry[0] in ("surface", "implicitSurface", "scalarField", "vectors3d") for entry in data)
        if has_grid_kinds:
            ax.set_xlim(*X_RANGE)
            ax.set_ylim(*(Y_RANGE or X_RANGE))
            if z_range:
                ax.set_zlim(*z_range)
            elif Z_RANGE or any(entry[0] in ("implicitSurface", "scalarField", "vectors3d") for entry in data):
                ax.set_zlim(*(Z_RANGE or X_RANGE))
        if any(entry[0] in ("implicitSurface", "parametricSurface", "line3d", "vectors3d") for entry in data) and not any(entry[0] == "surface" for entry in data):
            try:
                ax.set_aspect("equal")
            except Exception:
                pass
        ax.view_init(elev=cfg["view"][0], azim=cfg["view"][1])
        names = cfg["axisLabels"]
        ax.set_xlabel(names[0], color=t["text"], labelpad=2)
        ax.set_ylabel(names[1], color=t["text"], labelpad=2)
        ax.set_zlabel(names[2], color=t["text"], labelpad=2)
        if colorbar_source is not None:
            bar = fig.colorbar(colorbar_source, ax=ax, shrink=0.55, pad=0.1)
            bar.ax.tick_params(colors=t["text"], labelsize=8)
            bar.outline.set_edgecolor(t["axis"])
        if any(h.get_label() for h in handles) and len(handles) > 0 and any(labels):
            ax.legend(handles=[h for h in handles if h.get_label()], frameon=False, labelcolor=t["text"], loc="upper left", fontsize=9)
    else:
        style_axes_2d(ax, t)
        equal = not curve_values and any(entry[0] in ("implicit", "region", "line", "vectors") for entry in data)
        y_range = value_range if curve_values else (Y_RANGE or (X_RANGE if any(entry[0] in ("implicit", "region", "vectors", "field") for entry in data) else value_range))
        for i, entry in enumerate(data):
            color = colors[i % len(colors)]
            kind = entry[0]
            label = labels[i] or None
            if kind == "curve":
                ax.plot(entry[1], entry[2], color=color, lw=2.0, label=label, zorder=3)
            elif kind == "line":
                ax.plot(entry[1], entry[2], color=color, lw=2.0, label=label, zorder=3)
            elif kind == "implicit":
                ax.contour(entry[1], entry[2], entry[3], levels=[0], colors=[color], linewidths=2.0, zorder=3)
                handles.append(matplotlib.lines.Line2D([], [], color=color, lw=2.0, label=label))
            elif kind == "region":
                F = entry[3]
                inside = np.where(np.isfinite(F), (F <= 0).astype(float), np.nan)
                ax.contourf(entry[1], entry[2], inside, levels=[0.5, 1.5], colors=[color], alpha=0.28, zorder=2)
                ax.contour(entry[1], entry[2], F, levels=[0], colors=[color], linewidths=1.4, zorder=3)
                handles.append(Patch(color=color, alpha=0.5, label=label))
            elif kind == "field":
                Xg, Yg, Zg = entry[1], entry[2], entry[3]
                lo_hi = auto_range([Zg], Z_RANGE)
                norm = Normalize(*lo_hi) if lo_hi else None
                if STYLE == "heatmap":
                    colorbar_source = ax.pcolormesh(Xg, Yg, Zg, cmap=cmap, norm=norm, shading="auto", rasterized=True, zorder=1)
                    ax.contour(Xg, Yg, Zg, levels=10, colors=[t["contour"]], linewidths=0.5, norm=norm, zorder=2)
                else:
                    colorbar_source = ax.contourf(Xg, Yg, Zg, levels=16, cmap=cmap, norm=norm, zorder=1)
                    lines = ax.contour(Xg, Yg, Zg, levels=16, colors=[t["contour"]], linewidths=0.6, norm=norm, zorder=2)
                    try:
                        ax.clabel(lines, lines.levels[::2], inline=True, fontsize=7, colors=[t["text"]])
                    except Exception:
                        pass
            elif kind == "vectors":
                Xg, Yg, (U, V) = entry[1], entry[2], entry[3]
                speed = np.hypot(U, V)
                if STYLE == "arrows":
                    length = np.where(speed > 0, speed, 1)
                    colorbar_source = ax.quiver(Xg, Yg, U / length, V / length, speed, cmap=cmap, pivot="mid", scale=32, width=0.004, zorder=3)
                else:
                    stream = ax.streamplot(Xg[0], Yg[:, 0], U, V, color=speed, cmap=cmap, density=1.25, linewidth=1.2, arrowsize=1.0, zorder=3)
                    colorbar_source = stream.lines
        if marks:
            for (mx, my, what) in marks:
                ax.plot([mx], [my], "o", ms=5, color=t["text"], zorder=5)
                ax.annotate("(%s | %s)" % (number(mx), number(my)), (mx, my), textcoords="offset points", xytext=(6, 6 if what != "min" else -13), fontsize=7.5, color=t["text"], zorder=6,
                            bbox=dict(boxstyle="round,pad=0.15", fc=t["background"], ec="none", alpha=0.85))
        if any(entry[0] in ("implicit", "region", "field", "vectors", "curve") for entry in data):
            ax.set_xlim(*X_RANGE)
        if y_range:
            ax.set_ylim(*y_range)
        if equal:
            ax.set_aspect("equal", adjustable="datalim" if any(entry[0] == "line" for entry in data) else "box")
        ylo, yhi = ax.get_ylim()
        xlo, xhi = ax.get_xlim()
        if ylo < 0 < yhi:
            ax.axhline(0, color=t["axis"], lw=0.9, zorder=1)
        if xlo < 0 < xhi:
            ax.axvline(0, color=t["axis"], lw=0.9, zorder=1)
        names = cfg["axisLabels"]
        ax.set_xlabel(names[0], color=t["text"])
        if names[1]:
            ax.set_ylabel(names[1], color=t["text"])
        if colorbar_source is not None:
            bar = fig.colorbar(colorbar_source, ax=ax, shrink=0.85, pad=0.02)
            bar.ax.tick_params(colors=t["text"], labelsize=8)
            bar.outline.set_edgecolor(t["axis"])
        legend_handles, legend_labels = ax.get_legend_handles_labels()
        legend_handles += [h for h in handles if h.get_label()]
        if legend_handles and any(labels):
            ax.legend(handles=legend_handles, frameon=False, labelcolor=t["text"])
    if MODE == "3d":
        fig.subplots_adjust(left=0.0, right=0.94 if colorbar_source is None else 1.0, bottom=0.04, top=0.98)
    else:
        fig.tight_layout()
    fig.savefig(path, dpi=dpi, facecolor=t["background"])
    plt.close(fig)


def draw_all(labels):
    if QUICK:
        draw("dark", OUT + "/dark.png", labels, 110)
        return
    draw("light", OUT + "/light.png", labels, 200)
    draw("dark", OUT + "/dark.png", labels, 200)
    draw("light", OUT + "/plot.pdf", labels, 300)


labels = ["$" + label + "$" if label else "" for label in cfg["labels"]]
try:
    draw_all(labels)
except Exception:
    try:
        draw_all(cfg["plainLabels"])
    except Exception:
        cfg["axisLabels"] = ["", "", ""]
        draw_all(cfg["plainLabels"])
"""#
}
