import SwiftUI

// The pictures of a note's progress. Each one is drawn from a single number between 0 and 1, which SwiftUI
// interpolates (the views are `Animatable`), so ticking a to-do off makes the glass fill, the plant grow and the
// rocket fly a little further instead of jumping. Nothing moves while the number stays the same: no timers.

/// Colours the pictures share; deeper in the light design, as the app's other colours.
enum NoteArtColor {
    static let water = Theme.dynamic(dark: 0x5AB8FF, light: 0x2C8BE0)
    static let waterDeep = Theme.dynamic(dark: 0x2D6FD8, light: 0x1F5FBF)
    static let leaf = Theme.dynamic(dark: 0x58D08A, light: 0x23A05C)
    static let leafDark = Theme.dynamic(dark: 0x2E9A5C, light: 0x177A43)
    static let terracotta = Theme.dynamic(dark: 0xD9774A, light: 0xC2582B)
    static let soil = Theme.dynamic(dark: 0x5A3B28, light: 0x6B442B)
    static let petal = Theme.dynamic(dark: 0xFF8FB8, light: 0xE0558A)
    static let sun = Theme.dynamic(dark: 0xFFD166, light: 0xF2B01E)
    static let rock = Theme.dynamic(dark: 0x6E7A99, light: 0x7B88A8)
    static let rockLight = Theme.dynamic(dark: 0x9AA6C4, light: 0xA6B2CF)
    static let snow = Theme.dynamic(dark: 0xF4F7FF, light: 0xD9E0EF)
    static let moonLit = Theme.dynamic(dark: 0xF4ECD0, light: 0xF1E2A8)
    static let moonDark = Theme.dynamic(dark: 0x24242E, light: 0xD9D9E3)
    static let crust = Theme.dynamic(dark: 0xD69A55, light: 0xC9873F)
    static let cheese = Theme.dynamic(dark: 0xFFC94D, light: 0xF5B52E)
    static let pepperoni = Theme.dynamic(dark: 0xE0503C, light: 0xC93A27)
    static let shell = Theme.dynamic(dark: 0xC98A4B, light: 0xB06F30)
    static let snailBody = Theme.dynamic(dark: 0xE9D3A8, light: 0xD9BC86)
    static let earth = Theme.dynamic(dark: 0x3E8BFF, light: 0x2F74E0)
    static let flame = Theme.dynamic(dark: 0xFF9F45, light: 0xF07D1A)
}

/// The picture of a note's progress in its chosen style.
struct NoteProgressArt: View {
    let style: NoteProgressStyle
    let progress: NoteProgress
    /// The top-level to-dos with to-dos of their own, for the rings.
    var groups: [Double] = []
    /// Smaller, for panels.
    var compact = false

    var body: some View {
        art
            .frame(width: style.isWide ? nil : (compact ? 78 : 118), height: height)
            .frame(maxWidth: style.isWide ? .infinity : nil)
            .animation(.spring(response: 0.7, dampingFraction: 0.82), value: progress)
            .accessibilityElement()
            .accessibilityLabel("Fortschritt: \(progress.percent) Prozent, \(progress.label)")
    }

    private var height: CGFloat {
        switch style {
        case .bar: compact ? 22 : 30
        case .pixel: compact ? 30 : 40
        case .rocket, .snail: compact ? 46 : 64
        default: compact ? 66 : 96
        }
    }

    @ViewBuilder
    private var art: some View {
        let value = progress.fraction
        switch style {
        case .bar: NoteBarArt(value: value, label: "\(progress.percent) %")
        case .rings: NoteRingsArt(value: value, groups: groups, label: "\(progress.percent) %")
        case .glass: NoteGlassArt(value: value)
        case .plant: NotePlantArt(value: value)
        case .rocket: NoteRocketArt(value: value)
        case .summit: NoteSummitArt(value: value)
        case .battery: NoteBatteryArt(value: value)
        case .moon: NoteMoonArt(value: value)
        case .pizza: NotePizzaArt(value: value)
        case .snail: NoteSnailArt(value: value)
        case .gauge: NoteGaugeArt(value: value)
        case .pixel: NotePixelArt(value: value)
        }
    }
}

private func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double { min(max(value, low), high) }

/// How far a stage between `start` and `end` of the whole has come, 0…1.
private func stage(_ value: Double, _ start: Double, _ end: Double) -> Double { clamp((value - start) / (end - start)) }

// MARK: - Bar

private struct NoteBarArt: View, Animatable {
    var value: Double
    let label: String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                let height = min(geometry.size.height, 12)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent, value >= 0.999 ? Theme.success : Theme.accent.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geometry.size.width * value))
                        .opacity(value > 0.004 ? 1 : 0)
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.22)).frame(height: height * 0.35).padding(.horizontal, height * 0.35).padding(.top, 1.5)
                                .frame(width: max(height, geometry.size.width * value), alignment: .leading)
                                .opacity(value > 0.04 ? 1 : 0)
                        }
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(value >= 0.999 ? Theme.success : Theme.textSecondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }
}

// MARK: - Rings

/// One ring for the whole and one for each of up to three main to-dos, like the rings of a fitness watch.
private struct NoteRingsArt: View {
    let value: Double
    let groups: [Double]
    let label: String

    private static let colors = [Theme.accent, Theme.success, Theme.warning, NoteArtColor.petal]

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let values = [value] + groups.prefix(3)
            let line = max(5, side * (values.count > 2 ? 0.085 : 0.11))
            let gap = line * 0.28
            ZStack {
                ForEach(Array(values.enumerated()), id: \.offset) { index, fraction in
                    let inset = CGFloat(index) * (line + gap) + line / 2
                    let color = Self.colors[index % Self.colors.count]
                    Circle()
                        .stroke(color.opacity(0.16), lineWidth: line)
                        .padding(inset)
                    Circle()
                        .trim(from: 0, to: max(0.0001, fraction))
                        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                        .opacity(fraction > 0.001 ? 1 : 0)
                }
                let inner = side - 2 * (CGFloat(values.count) * (line + gap))
                if inner > 26 {
                    Text(label)
                        .font(.system(size: max(9, inner * 0.26), weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(width: inner * 0.9)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Glass

private struct NoteGlassArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let h = size.height * 0.86
            let topWidth = min(size.width * 0.62, h * 0.78)
            let bottomWidth = topWidth * 0.74
            let top = (size.height - h) / 2 + h * 0.04
            let bottom = top + h * 0.9
            let mid = size.width / 2
            let glass = Path { path in
                path.move(to: CGPoint(x: mid - topWidth / 2, y: top))
                path.addLine(to: CGPoint(x: mid - bottomWidth / 2, y: bottom - 6))
                path.addQuadCurve(to: CGPoint(x: mid - bottomWidth / 2 + 6, y: bottom), control: CGPoint(x: mid - bottomWidth / 2, y: bottom))
                path.addLine(to: CGPoint(x: mid + bottomWidth / 2 - 6, y: bottom))
                path.addQuadCurve(to: CGPoint(x: mid + bottomWidth / 2, y: bottom - 6), control: CGPoint(x: mid + bottomWidth / 2, y: bottom))
                path.addLine(to: CGPoint(x: mid + topWidth / 2, y: top))
            }
            let closed = glass.applying(.identity)
            var inside = closed
            inside.closeSubpath()

            // The water, with a wave that sloshes while it rises.
            let level = bottom - (bottom - top - 4) * value
            let phase = value * .pi * 6
            let amplitude = value > 0.01 && value < 0.995 ? 2.2 : 0
            var water = Path()
            water.move(to: CGPoint(x: 0, y: size.height))
            for step in 0...40 {
                let x = size.width * Double(step) / 40
                water.addLine(to: CGPoint(x: x, y: level + sin(phase + x / size.width * .pi * 3) * amplitude))
            }
            water.addLine(to: CGPoint(x: size.width, y: size.height))
            water.closeSubpath()
            context.drawLayer { layer in
                layer.clip(to: inside)
                layer.fill(water, with: .linearGradient(Gradient(colors: [NoteArtColor.water.opacity(0.85), NoteArtColor.waterDeep]),
                                                        startPoint: CGPoint(x: mid, y: level), endPoint: CGPoint(x: mid, y: bottom)))
                // Bubbles, only where there is water.
                let bubbles: [(Double, Double, Double)] = [(0.42, 0.85, 2.2), (0.6, 0.7, 1.6), (0.5, 0.55, 2.6), (0.38, 0.4, 1.4), (0.58, 0.28, 2)]
                for (bx, by, r) in bubbles {
                    let point = CGPoint(x: mid + (bx - 0.5) * topWidth, y: bottom - (bottom - top) * (1 - by))
                    guard point.y > level + 4 else { continue }
                    layer.stroke(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.55)), lineWidth: 1)
                }
            }
            // A straw and a slice of lemon once it is full.
            if value > 0.97 {
                let alpha = stage(value, 0.97, 1)
                var straw = Path()
                straw.move(to: CGPoint(x: mid + bottomWidth * 0.12, y: bottom - 8))
                straw.addLine(to: CGPoint(x: mid + topWidth * 0.36, y: top - h * 0.12))
                straw.addLine(to: CGPoint(x: mid + topWidth * 0.62, y: top - h * 0.12))
                context.stroke(straw, with: .color(NoteArtColor.petal.opacity(alpha)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                let lemon = CGRect(x: mid - topWidth / 2 - 7, y: top - 9, width: 18, height: 18)
                context.fill(Path { $0.addArc(center: CGPoint(x: lemon.midX, y: lemon.midY), radius: 9, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true) },
                             with: .color(NoteArtColor.sun.opacity(alpha)))
            }
            context.stroke(glass, with: .color(Theme.ink.opacity(0.38)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            var shine = Path()
            shine.move(to: CGPoint(x: mid - topWidth / 2 + 6, y: top + 6))
            shine.addLine(to: CGPoint(x: mid - bottomWidth / 2 + 5, y: bottom - 12))
            context.stroke(shine, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

// MARK: - Plant

private struct NotePlantArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height * 1.05)
            let mid = size.width / 2
            let potTop = size.height - unit * 0.3
            let potBottom = size.height - unit * 0.03
            let potWidth = unit * 0.42
            // The pot and its soil.
            let pot = Path { path in
                path.move(to: CGPoint(x: mid - potWidth / 2, y: potTop))
                path.addLine(to: CGPoint(x: mid + potWidth / 2, y: potTop))
                path.addLine(to: CGPoint(x: mid + potWidth * 0.36, y: potBottom))
                path.addLine(to: CGPoint(x: mid - potWidth * 0.36, y: potBottom))
                path.closeSubpath()
            }
            context.fill(pot, with: .color(NoteArtColor.terracotta))
            context.fill(Path(roundedRect: CGRect(x: mid - potWidth * 0.56, y: potTop - unit * 0.05, width: potWidth * 1.12, height: unit * 0.075), cornerRadius: 2.5),
                         with: .color(NoteArtColor.terracotta))
            context.fill(Path(ellipseIn: CGRect(x: mid - potWidth * 0.46, y: potTop - unit * 0.07, width: potWidth * 0.92, height: unit * 0.05)), with: .color(NoteArtColor.soil))

            let ground = potTop - unit * 0.05
            if value < 0.03 {
                // A seed waiting.
                context.fill(Path(ellipseIn: CGRect(x: mid - 4, y: ground - 5, width: 8, height: 5.5)), with: .color(NoteArtColor.soil.opacity(0.9)))
                return
            }
            let stemHeight = unit * (0.06 + 0.56 * value)
            let tip = CGPoint(x: mid + sin(value * 5) * unit * 0.03, y: ground - stemHeight)
            var stem = Path()
            stem.move(to: CGPoint(x: mid, y: ground))
            stem.addQuadCurve(to: tip, control: CGPoint(x: mid - unit * 0.06, y: ground - stemHeight * 0.5))
            context.stroke(stem, with: .color(NoteArtColor.leafDark), style: StrokeStyle(lineWidth: max(2, unit * 0.028), lineCap: .round))

            // Leaves come one after another, alternating sides.
            let thresholds = [0.12, 0.28, 0.44, 0.6, 0.76]
            for (index, threshold) in thresholds.enumerated() {
                let grow = stage(value, threshold, threshold + 0.12)
                guard grow > 0 else { continue }
                let along = Double(index + 1) / (Double(thresholds.count) + 1.6)
                let base = CGPoint(x: mid + (tip.x - mid) * along - unit * 0.02 * along, y: ground - stemHeight * along)
                let side: Double = index.isMultiple(of: 2) ? 1 : -1
                var leaf = context
                leaf.translateBy(x: base.x, y: base.y)
                leaf.rotate(by: .degrees(-side * 30))
                leaf.scaleBy(x: grow, y: grow)
                let length = unit * 0.2
                let shape = Path { path in
                    path.move(to: .zero)
                    path.addQuadCurve(to: CGPoint(x: side * length, y: -length * 0.18), control: CGPoint(x: side * length * 0.45, y: -length * 0.55))
                    path.addQuadCurve(to: .zero, control: CGPoint(x: side * length * 0.55, y: length * 0.25))
                }
                leaf.fill(shape, with: .linearGradient(Gradient(colors: [NoteArtColor.leaf, NoteArtColor.leafDark]), startPoint: .zero, endPoint: CGPoint(x: side * length, y: 0)))
            }

            // A bud, then the flower.
            let bloom = stage(value, 0.86, 1)
            if bloom > 0 {
                let radius = unit * 0.075 * bloom
                for petal in 0..<6 {
                    let angle = Double(petal) / 6 * 2 * .pi + value
                    let center = CGPoint(x: tip.x + cos(angle) * radius * 1.15, y: tip.y + sin(angle) * radius * 1.15)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(NoteArtColor.petal))
                }
                context.fill(Path(ellipseIn: CGRect(x: tip.x - radius * 0.8, y: tip.y - radius * 0.8, width: radius * 1.6, height: radius * 1.6)), with: .color(NoteArtColor.sun))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: tip.x - 3.5, y: tip.y - 4.5, width: 7, height: 8)), with: .color(NoteArtColor.leaf))
            }
        }
    }
}

// MARK: - Rocket

private struct NoteRocketArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    private static let stars: [(Double, Double, Double)] = [(0.22, 0.18, 1.2), (0.35, 0.62, 0.9), (0.48, 0.12, 1.4), (0.6, 0.78, 1), (0.7, 0.2, 0.8),
                                                            (0.78, 0.7, 1.3), (0.28, 0.85, 0.8), (0.55, 0.42, 0.7), (0.15, 0.45, 0.9), (0.85, 0.9, 0.8)]

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            for (x, y, r) in Self.stars {
                context.fill(Path(ellipseIn: CGRect(x: x * w - r, y: y * h - r, width: 2 * r, height: 2 * r)), with: .color(Theme.ink.opacity(0.35)))
            }
            // Earth on the left, the moon on the right.
            let earthRadius = h * 0.34
            let earth = CGPoint(x: earthRadius * 0.9, y: h * 0.68)
            context.fill(Path(ellipseIn: CGRect(x: earth.x - earthRadius, y: earth.y - earthRadius, width: 2 * earthRadius, height: 2 * earthRadius)), with: .color(NoteArtColor.earth))
            context.fill(Path(ellipseIn: CGRect(x: earth.x - earthRadius * 0.55, y: earth.y - earthRadius * 0.6, width: earthRadius * 0.7, height: earthRadius * 0.5)), with: .color(NoteArtColor.leaf))
            context.fill(Path(ellipseIn: CGRect(x: earth.x + earthRadius * 0.05, y: earth.y + earthRadius * 0.1, width: earthRadius * 0.6, height: earthRadius * 0.45)), with: .color(NoteArtColor.leaf))
            let moonRadius = h * 0.24
            let moon = CGPoint(x: w - moonRadius * 1.15, y: h * 0.46)
            context.fill(Path(ellipseIn: CGRect(x: moon.x - moonRadius, y: moon.y - moonRadius, width: 2 * moonRadius, height: 2 * moonRadius)), with: .color(NoteArtColor.moonLit))
            for (dx, dy, r) in [(-0.35, -0.2, 0.22), (0.3, 0.25, 0.16), (0.05, 0.45, 0.12)] {
                context.fill(Path(ellipseIn: CGRect(x: moon.x + dx * moonRadius - r * moonRadius, y: moon.y + dy * moonRadius - r * moonRadius, width: 2 * r * moonRadius, height: 2 * r * moonRadius)),
                             with: .color(NoteArtColor.rock.opacity(0.35)))
            }

            // The way there, dashed; behind the rocket it is drawn in.
            let start = CGPoint(x: earth.x + earthRadius * 0.7, y: earth.y - earthRadius * 0.75)
            let end = CGPoint(x: moon.x - moonRadius * 0.55, y: moon.y - moonRadius * 0.85)
            let control = CGPoint(x: (start.x + end.x) / 2, y: -h * 0.25)
            func point(_ t: Double) -> CGPoint {
                CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x,
                        y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y)
            }
            var route = Path()
            route.move(to: start)
            route.addQuadCurve(to: end, control: control)
            context.stroke(route, with: .color(Theme.ink.opacity(0.22)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
            context.stroke(route.trimmedPath(from: 0, to: value), with: .color(Theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            let t = clamp(value)
            let here = point(t)
            let ahead = point(min(1, t + 0.01))
            let behind = point(max(0, t - 0.01))
            var angle = atan2(ahead.y - behind.y, ahead.x - behind.x)
            if value > 0.985 { angle = .pi / 2 * 0.15 + .pi / 2 }
            var rocket = context
            rocket.translateBy(x: here.x, y: here.y)
            rocket.rotate(by: .radians(angle))
            let length = h * 0.3
            let body = Path { path in
                path.move(to: CGPoint(x: length * 0.55, y: 0))
                path.addQuadCurve(to: CGPoint(x: -length * 0.4, y: -length * 0.17), control: CGPoint(x: length * 0.2, y: -length * 0.24))
                path.addLine(to: CGPoint(x: -length * 0.4, y: length * 0.17))
                path.addQuadCurve(to: CGPoint(x: length * 0.55, y: 0), control: CGPoint(x: length * 0.2, y: length * 0.24))
            }
            if value > 0.005, value < 0.985 {
                let flame = Path { path in
                    path.move(to: CGPoint(x: -length * 0.4, y: -length * 0.1))
                    path.addQuadCurve(to: CGPoint(x: -length * (0.75 + 0.15 * sin(value * 40)), y: 0), control: CGPoint(x: -length * 0.6, y: -length * 0.12))
                    path.addQuadCurve(to: CGPoint(x: -length * 0.4, y: length * 0.1), control: CGPoint(x: -length * 0.6, y: length * 0.12))
                }
                rocket.fill(flame, with: .color(NoteArtColor.flame))
            }
            let fins = Path { path in
                path.move(to: CGPoint(x: -length * 0.2, y: -length * 0.17))
                path.addLine(to: CGPoint(x: -length * 0.48, y: -length * 0.34))
                path.addLine(to: CGPoint(x: -length * 0.4, y: -length * 0.1))
                path.move(to: CGPoint(x: -length * 0.2, y: length * 0.17))
                path.addLine(to: CGPoint(x: -length * 0.48, y: length * 0.34))
                path.addLine(to: CGPoint(x: -length * 0.4, y: length * 0.1))
            }
            rocket.fill(fins, with: .color(Theme.danger))
            rocket.fill(body, with: .color(Theme.dynamic(dark: 0xF2F2F7, light: 0xE6E6EE)))
            rocket.stroke(body, with: .color(Theme.ink.opacity(0.25)), lineWidth: 0.8)
            rocket.fill(Path(ellipseIn: CGRect(x: length * 0.04, y: -length * 0.07, width: length * 0.14, height: length * 0.14)), with: .color(NoteArtColor.water))

            // Landed: a flag on the moon.
            if value > 0.985 {
                let pole = CGPoint(x: moon.x + moonRadius * 0.45, y: moon.y - moonRadius * 0.85)
                var flag = Path()
                flag.move(to: pole)
                flag.addLine(to: CGPoint(x: pole.x, y: pole.y - h * 0.3))
                context.stroke(flag, with: .color(Theme.ink.opacity(0.6)), lineWidth: 1.2)
                context.fill(Path(CGRect(x: pole.x, y: pole.y - h * 0.3, width: h * 0.16, height: h * 0.1)), with: .color(Theme.accent))
            }
        }
    }
}

// MARK: - Summit

private struct NoteSummitArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let base = h * 0.96
            let peak = CGPoint(x: w * 0.56, y: h * 0.24)
            // A smaller mountain behind, then the one to climb with its snow.
            context.fill(Path { path in
                path.move(to: CGPoint(x: w * 0.02, y: base))
                path.addLine(to: CGPoint(x: w * 0.26, y: h * 0.47))
                path.addLine(to: CGPoint(x: w * 0.5, y: base))
            }, with: .color(NoteArtColor.rockLight.opacity(0.7)))
            let mountain = Path { path in
                path.move(to: CGPoint(x: w * 0.12, y: base))
                path.addLine(to: peak)
                path.addLine(to: CGPoint(x: w * 0.98, y: base))
                path.closeSubpath()
            }
            context.fill(mountain, with: .color(NoteArtColor.rock))
            context.fill(Path { path in
                path.move(to: peak)
                path.addLine(to: CGPoint(x: peak.x - w * 0.1, y: h * 0.41))
                path.addLine(to: CGPoint(x: peak.x - w * 0.045, y: h * 0.38))
                path.addLine(to: CGPoint(x: peak.x, y: h * 0.43))
                path.addLine(to: CGPoint(x: peak.x + w * 0.055, y: h * 0.37))
                path.addLine(to: CGPoint(x: peak.x + w * 0.11, y: h * 0.41))
                path.closeSubpath()
            }, with: .color(NoteArtColor.snow))

            // The path up, zigzag; done stretches are drawn in.
            let points = [CGPoint(x: w * 0.22, y: base - 2), CGPoint(x: w * 0.62, y: h * 0.78), CGPoint(x: w * 0.37, y: h * 0.62),
                          CGPoint(x: w * 0.6, y: h * 0.47), CGPoint(x: w * 0.48, y: h * 0.36), peak]
            var trail = Path()
            trail.addLines(points)
            context.stroke(trail, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 3]))
            context.stroke(trail.trimmedPath(from: 0, to: value), with: .color(NoteArtColor.sun), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            // The climber where the path has got to.
            var lengths: [Double] = []
            for index in 1..<points.count { lengths.append(hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)) }
            var remaining = lengths.reduce(0, +) * clamp(value)
            var climber = points[0]
            for (index, length) in lengths.enumerated() {
                if remaining <= length {
                    let t = length == 0 ? 0 : remaining / length
                    climber = CGPoint(x: points[index].x + (points[index + 1].x - points[index].x) * t, y: points[index].y + (points[index + 1].y - points[index].y) * t)
                    break
                }
                remaining -= length
                climber = points[index + 1]
            }
            let unit = h * 0.07
            if value > 0.985 {
                // Beside the flag, on the slope.
                climber.x = peak.x - unit * 1.6
                climber.y = peak.y + (peak.x - climber.x) * (base - peak.y) / (peak.x - w * 0.12)
            }
            if value > 0.985 {
                var pole = Path()
                pole.move(to: peak)
                pole.addLine(to: CGPoint(x: peak.x, y: peak.y - h * 0.21))
                context.stroke(pole, with: .color(Theme.ink.opacity(0.7)), lineWidth: 1.3)
                context.fill(Path { path in
                    path.move(to: CGPoint(x: peak.x, y: peak.y - h * 0.21))
                    path.addLine(to: CGPoint(x: peak.x + h * 0.17, y: peak.y - h * 0.16))
                    path.addLine(to: CGPoint(x: peak.x, y: peak.y - h * 0.11))
                }, with: .color(Theme.danger))
            }
            context.fill(Path(ellipseIn: CGRect(x: climber.x - unit * 0.55, y: climber.y - unit * 2.4, width: unit * 1.1, height: unit * 1.1)), with: .color(NoteArtColor.sun))
            context.fill(Path(roundedRect: CGRect(x: climber.x - unit * 0.5, y: climber.y - unit * 1.35, width: unit, height: unit * 1.35), cornerRadius: unit * 0.3),
                         with: .color(Theme.accent))
        }
    }
}

// MARK: - Battery

private struct NoteBatteryArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let width = min(size.width * 0.86, size.height * 1.6)
            let height = width * 0.5
            let rect = CGRect(x: (size.width - width) / 2 - 3, y: (size.height - height) / 2, width: width, height: height)
            let color = value < 0.25 ? Theme.danger : value < 0.6 ? Theme.warning : Theme.success
            context.stroke(Path(roundedRect: rect, cornerRadius: height * 0.2), with: .color(Theme.ink.opacity(0.45)), lineWidth: 2.2)
            context.fill(Path(roundedRect: CGRect(x: rect.maxX + 1.5, y: rect.midY - height * 0.16, width: 4.5, height: height * 0.32), cornerRadius: 1.5),
                         with: .color(Theme.ink.opacity(0.45)))
            let inner = rect.insetBy(dx: 4.5, dy: 4.5)
            // Five cells; the one being charged fills from the left.
            let cells = 5
            let gap: Double = 2.5
            let cellWidth = (inner.width - gap * Double(cells - 1)) / Double(cells)
            for cell in 0..<cells {
                let fill = clamp(value * Double(cells) - Double(cell))
                guard fill > 0 else { continue }
                let x = inner.minX + Double(cell) * (cellWidth + gap)
                context.fill(Path(roundedRect: CGRect(x: x, y: inner.minY, width: cellWidth * fill, height: inner.height), cornerRadius: 2.5), with: .color(color))
            }
            if value > 0.995 {
                var bolt = context.resolve(Image(systemName: "bolt.fill"))
                bolt.shading = .color(Theme.textPrimary)
                context.draw(bolt, in: CGRect(x: rect.midX - height * 0.22, y: rect.midY - height * 0.32, width: height * 0.44, height: height * 0.64))
            }
            context.draw(Text("\(Int((value * 100).rounded(.down))) %").font(.system(size: max(9, height * 0.28), weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: rect.midX + 2, y: rect.maxY + height * 0.32))
        }
    }
}

// MARK: - Moon

private struct NoteMoonArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) * 0.38
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (dx, dy, r) in [(-1.25, -0.9, 1.3), (1.2, -1.05, 1), (1.3, 0.8, 1.4), (-1.2, 1.0, 0.9), (0.1, -1.3, 0.8)] {
                context.fill(Path(ellipseIn: CGRect(x: center.x + dx * radius - r, y: center.y + dy * radius - r, width: 2 * r, height: 2 * r)), with: .color(Theme.ink.opacity(0.4)))
            }
            let disk = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            context.fill(disk, with: .color(NoteArtColor.moonDark))
            context.stroke(disk, with: .color(Theme.ink.opacity(0.12)), lineWidth: 1)

            // The lit part: the right half and the half ellipse of the terminator, which wanders from right to left.
            let phase = clamp(value)
            let terminator = radius * abs(1 - 2 * phase)
            var lit = Path()
            lit.move(to: CGPoint(x: center.x, y: center.y - radius))
            lit.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            for step in 0...48 {
                let angle = .pi / 2 - Double(step) / 48 * .pi
                let x = phase < 0.5 ? center.x + terminator * cos(angle) : center.x - terminator * cos(angle)
                lit.addLine(to: CGPoint(x: x, y: center.y + radius * sin(angle)))
            }
            lit.closeSubpath()
            if phase > 0.005 {
                if phase > 0.99 {
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: NoteArtColor.moonLit.opacity(0.7), radius: radius * 0.35))
                        layer.fill(disk, with: .color(NoteArtColor.moonLit))
                    }
                } else {
                    context.fill(lit, with: .color(NoteArtColor.moonLit))
                }
                context.drawLayer { layer in
                    layer.clip(to: phase > 0.99 ? disk : lit)
                    for (dx, dy, r) in [(-0.3, -0.25, 0.2), (0.32, 0.1, 0.14), (-0.05, 0.42, 0.11), (0.15, -0.5, 0.08)] {
                        layer.fill(Path(ellipseIn: CGRect(x: center.x + dx * radius - r * radius, y: center.y + dy * radius - r * radius, width: 2 * r * radius, height: 2 * r * radius)),
                                   with: .color(NoteArtColor.rock.opacity(0.28)))
                    }
                }
            }
        }
    }
}

// MARK: - Pizza

private struct NotePizzaArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    private static let toppings: [(angle: Double, distance: Double, size: Double)] = [
        (20, 0.55, 0.13), (65, 0.3, 0.11), (110, 0.62, 0.12), (150, 0.35, 0.12), (200, 0.6, 0.13),
        (245, 0.28, 0.1), (285, 0.62, 0.12), (330, 0.38, 0.11), (175, 0.72, 0.09), (40, 0.78, 0.09),
    ]

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) * 0.43
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let plate = Path(ellipseIn: CGRect(x: center.x - radius * 1.08, y: center.y - radius * 1.08, width: radius * 2.16, height: radius * 2.16))
            context.stroke(plate, with: .color(Theme.ink.opacity(0.18)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            guard value > 0.003 else { return }
            let sweep = 360 * clamp(value)
            var pizza = Path()
            pizza.move(to: center)
            pizza.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + sweep), clockwise: false)
            pizza.closeSubpath()
            context.fill(pizza, with: .color(NoteArtColor.crust))
            var cheese = Path()
            cheese.move(to: center)
            cheese.addArc(center: center, radius: radius * 0.84, startAngle: .degrees(-90), endAngle: .degrees(-90 + sweep), clockwise: false)
            cheese.closeSubpath()
            context.fill(cheese, with: .color(NoteArtColor.cheese))
            context.drawLayer { layer in
                layer.clip(to: cheese)
                for topping in Self.toppings {
                    let angle = (topping.angle - 90) * .pi / 180
                    let point = CGPoint(x: center.x + cos(angle) * radius * topping.distance, y: center.y + sin(angle) * radius * topping.distance)
                    let r = radius * topping.size
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(NoteArtColor.pepperoni))
                }
            }
            // The cuts between the eight slices.
            for slice in 0..<8 where Double(slice) * 45 <= sweep {
                let angle = (Double(slice) * 45 - 90) * .pi / 180
                var cut = Path()
                cut.move(to: center)
                cut.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
                context.stroke(cut, with: .color(NoteArtColor.crust.opacity(0.75)), lineWidth: 1)
            }
        }
    }
}

// MARK: - Snail

private struct NoteSnailArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let ground = h * 0.84
            var grass = Path()
            grass.move(to: CGPoint(x: 0, y: ground))
            grass.addLine(to: CGPoint(x: w, y: ground))
            context.stroke(grass, with: .color(NoteArtColor.leafDark.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for tuft in stride(from: 0.06, to: 0.86, by: 0.11) {
                var blade = Path()
                blade.move(to: CGPoint(x: w * tuft, y: ground))
                blade.addLine(to: CGPoint(x: w * tuft + 2, y: ground - h * 0.1))
                blade.move(to: CGPoint(x: w * tuft + 3, y: ground))
                blade.addLine(to: CGPoint(x: w * tuft + 5.5, y: ground - h * 0.07))
                context.stroke(blade, with: .color(NoteArtColor.leaf.opacity(0.6)), lineWidth: 1.2)
            }
            // The lettuce at the end of the way.
            let lettuce = CGPoint(x: w - h * 0.42, y: ground)
            for (dx, r, color) in [(-0.16, 0.26, NoteArtColor.leafDark), (0.14, 0.27, NoteArtColor.leafDark), (0, 0.3, NoteArtColor.leaf)] {
                context.fill(Path(ellipseIn: CGRect(x: lettuce.x + dx * h - r * h, y: lettuce.y - r * h * 1.7, width: 2 * r * h, height: r * h * 1.75)), with: .color(color))
            }
            var vein = Path()
            vein.move(to: CGPoint(x: lettuce.x, y: ground - 2))
            vein.addLine(to: CGPoint(x: lettuce.x, y: ground - h * 0.42))
            context.stroke(vein, with: .color(.white.opacity(0.4)), lineWidth: 1)

            // The snail and its shiny trail.
            let start = h * 0.5
            let finish = lettuce.x - h * 0.62
            let x = start + (finish - start) * clamp(value)
            if value > 0.005 {
                var trail = Path()
                trail.move(to: CGPoint(x: start - h * 0.3, y: ground - 1.5))
                trail.addLine(to: CGPoint(x: x - h * 0.3, y: ground - 1.5))
                context.stroke(trail, with: .color(NoteArtColor.water.opacity(0.45)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
            let unit = h * 0.3
            let body = Path { path in
                path.move(to: CGPoint(x: x - unit * 1.3, y: ground - 1))
                path.addLine(to: CGPoint(x: x + unit * 1.05, y: ground - 1))
                path.addQuadCurve(to: CGPoint(x: x + unit * 0.85, y: ground - unit * 0.75), control: CGPoint(x: x + unit * 1.35, y: ground - unit * 0.5))
                path.addLine(to: CGPoint(x: x - unit * 1.1, y: ground - unit * 0.32))
                path.closeSubpath()
            }
            context.fill(body, with: .color(NoteArtColor.snailBody))
            for (dx, top) in [(0.78, 1.45), (1.0, 1.3)] {
                var stalk = Path()
                stalk.move(to: CGPoint(x: x + unit * 0.88, y: ground - unit * 0.65))
                stalk.addLine(to: CGPoint(x: x + unit * dx, y: ground - unit * top))
                context.stroke(stalk, with: .color(NoteArtColor.snailBody), lineWidth: 1.6)
                context.fill(Path(ellipseIn: CGRect(x: x + unit * dx - 2, y: ground - unit * top - 2, width: 4, height: 4)), with: .color(Theme.ink.opacity(0.7)))
            }
            let shellCenter = CGPoint(x: x - unit * 0.2, y: ground - unit * 0.95)
            let shellRadius = unit * 0.78
            context.fill(Path(ellipseIn: CGRect(x: shellCenter.x - shellRadius, y: shellCenter.y - shellRadius, width: 2 * shellRadius, height: 2 * shellRadius)), with: .color(NoteArtColor.shell))
            var spiral = Path()
            for step in 0...60 {
                let t = Double(step) / 60
                let angle = t * 4.2 * .pi + value * 10
                let r = shellRadius * 0.85 * (1 - t)
                let point = CGPoint(x: shellCenter.x + cos(angle) * r, y: shellCenter.y + sin(angle) * r)
                if step == 0 { spiral.move(to: point) } else { spiral.addLine(to: point) }
            }
            context.stroke(spiral, with: .color(Theme.dynamic(dark: 0x7A4A20, light: 0x7A4A20).opacity(0.8)), lineWidth: 1.3)

            // Arrived: a little heart.
            if value > 0.985 {
                var heart = context.resolve(Image(systemName: "heart.fill"))
                heart.shading = .color(NoteArtColor.petal)
                var hearts = context
                hearts.opacity = stage(value, 0.985, 1)
                hearts.draw(heart, in: CGRect(x: x + unit * 0.9, y: ground - unit * 2.5, width: unit * 0.8, height: unit * 0.7))
            }
        }
    }
}

// MARK: - Gauge

private struct NoteGaugeArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width / 2, size.height * 0.78) * 0.9
            let center = CGPoint(x: size.width / 2, y: size.height * 0.72)
            let line = radius * 0.16
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(arc, with: .color(Theme.ink.opacity(0.08)), style: StrokeStyle(lineWidth: line, lineCap: .round))
            context.stroke(arc.trimmedPath(from: 0, to: max(0.001, value)),
                           with: .linearGradient(Gradient(colors: [Theme.danger, Theme.warning, Theme.success]),
                                                 startPoint: CGPoint(x: center.x - radius, y: center.y), endPoint: CGPoint(x: center.x + radius, y: center.y)),
                           style: StrokeStyle(lineWidth: line, lineCap: .round))
            for tick in 0...10 {
                let angle = .pi + Double(tick) / 10 * .pi
                let inner = radius - line * (tick.isMultiple(of: 5) ? 1.6 : 1.1)
                var mark = Path()
                mark.move(to: CGPoint(x: center.x + cos(angle) * (radius - line * 0.7), y: center.y + sin(angle) * (radius - line * 0.7)))
                mark.addLine(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                context.stroke(mark, with: .color(Theme.ink.opacity(0.3)), lineWidth: tick.isMultiple(of: 5) ? 1.4 : 0.8)
            }
            let angle = .pi + clamp(value) * .pi
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 0.78, y: center.y + sin(angle) * radius * 0.78))
            context.stroke(needle, with: .color(Theme.textPrimary), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)), with: .color(Theme.textPrimary))
            context.draw(Text("\(Int((value * 100).rounded(.down))) %").font(.system(size: max(9, radius * 0.27), weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: center.x, y: center.y + radius * 0.26))
        }
    }
}

// MARK: - Pixel

private struct NotePixelArt: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let blocks = 20
        let filled = Int((clamp(value) * Double(blocks)).rounded(.down))
        HStack(spacing: 10) {
            GeometryReader { geometry in
                let gap: CGFloat = 2
                let side = min(geometry.size.height - 8, (geometry.size.width - 8 - gap * CGFloat(blocks - 1)) / CGFloat(blocks))
                HStack(spacing: gap) {
                    ForEach(0..<blocks, id: \.self) { index in
                        Rectangle()
                            .fill(index < filled ? (value >= 0.999 ? Theme.success : Theme.accent) : Theme.ink.opacity(0.07))
                            .frame(width: side, height: side)
                    }
                }
                .padding(4)
                .overlay(Rectangle().strokeBorder(Theme.ink.opacity(0.45), lineWidth: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            Text(value >= 0.999 ? "FERTIG!" : "LADE \(Int((value * 100).rounded(.down)))%")
                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(value >= 0.999 ? Theme.success : Theme.textSecondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
    }
}

// MARK: - Picker

/// All displays side by side, each with a sample filling; a click chooses one.
struct NoteStylePicker: View {
    let selection: NoteProgressStyle
    let onPick: (NoteProgressStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    private let sample = NoteProgress(done: 5, total: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fortschrittsanzeige")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(132), spacing: 8), count: 4), spacing: 8) {
                ForEach(NoteProgressStyle.allCases) { style in
                    Button {
                        onPick(style)
                        dismiss()
                    } label: {
                        VStack(spacing: 5) {
                            NoteProgressArt(style: style, progress: sample, groups: [0.8, 0.45, 0.6], compact: true)
                                .frame(width: 116, height: 66)
                                .allowsHitTesting(false)
                            Text(style.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(style.tagline)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(8)
                        .frame(width: 132)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style == selection ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style == selection ? Theme.accent : Theme.border, lineWidth: style == selection ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(style.title): \(style.tagline)")
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Celebration

/// A short burst of confetti when the last to-do is ticked off. It only runs for that moment.
struct NoteConfetti: View {
    let start: Date
    static let duration: TimeInterval = 1.6

    private static let pieces: [(dx: Double, dy: Double, spin: Double, color: Int, size: Double)] = (0..<46).map { index in
        let angle = Double(index) / 46 * 2 * .pi + Double(index % 5) * 0.31
        let speed = 70 + Double((index * 37) % 60)
        return (cos(angle) * speed, sin(angle) * speed - 60, Double((index * 53) % 360), index % 5, 3 + Double(index % 3))
    }

    private static let colors = [Theme.accent, Theme.success, Theme.warning, NoteArtColor.petal, NoteArtColor.water]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t < Self.duration else { return }
                let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
                context.opacity = 1 - max(0, (t - Self.duration * 0.55) / (Self.duration * 0.45))
                for piece in Self.pieces {
                    let x = center.x + piece.dx * t
                    let y = center.y + piece.dy * t + 140 * t * t
                    var bit = context
                    bit.translateBy(x: x, y: y)
                    bit.rotate(by: .degrees(piece.spin + t * 400))
                    bit.fill(Path(CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)), with: .color(Self.colors[piece.color]))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small ring for lists: how far a note is, at a glance.
struct NoteMiniRing: View {
    let progress: NoteProgress
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink.opacity(0.12), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0.0001, progress.fraction))
                .stroke(progress.isComplete ? Theme.success : Theme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress.done > 0 ? 1 : 0)
            if progress.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Theme.success)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
    }
}
