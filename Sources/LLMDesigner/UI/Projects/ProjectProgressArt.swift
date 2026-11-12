import SwiftUI

// The progress pictures of a project. The twelve of Notes are drawn at their own size and scaled to the block; the
// four of the project's own are drawn to the block's size. All of them follow one number between 0 and 1, which
// SwiftUI interpolates, so ticking something off moves the picture instead of making it jump.

struct ProjectProgressArt: View {
    let style: ProjectProgressStyle
    let progress: NoteProgress
    let project: Project
    let accent: Color

    var body: some View {
        Group {
            switch style {
            case .classic(let classic):
                ScaledNoteArt(style: classic, progress: progress, groups: [project.progress(.tasks), project.progress(.todos), project.progress(.milestones)]
                    .filter { $0.total > 0 }.map(\.fraction))
            case .journey:
                JourneyArt(value: progress.fraction, stations: project.sortedMilestones.map { ($0.displayTitle, $0.isDone) }, accent: accent)
            case .constellation:
                ConstellationArt(value: progress.fraction, stars: min(max(progress.total, 7), 28), accent: accent)
            case .hourglass:
                HourglassArt(value: progress.fraction, accent: accent)
            case .skyline:
                SkylineArt(value: progress.fraction, accent: accent)
            }
        }
        .animation(.spring(response: 0.8, dampingFraction: 0.85), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Fortschritt: \(progress.percent) Prozent")
    }
}

/// A picture of Notes, at its natural size, scaled to fit.
private struct ScaledNoteArt: View {
    let style: NoteProgressStyle
    let progress: NoteProgress
    let groups: [Double]

    var body: some View {
        GeometryReader { geometry in
            let natural = naturalSize(width: geometry.size.width)
            let scale = max(0.4, min(geometry.size.width / natural.width, geometry.size.height / natural.height, 2.4))
            NoteProgressArt(style: style, progress: progress, groups: groups)
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func naturalSize(width: CGFloat) -> CGSize {
        switch style {
        case .bar: CGSize(width: max(width / 1.4, 160), height: 30)
        case .pixel: CGSize(width: max(width / 1.4, 160), height: 40)
        case .rocket, .snail: CGSize(width: max(width / 1.4, 200), height: 64)
        default: CGSize(width: 118, height: 96)
        }
    }
}

private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

/// Numbers that look random but are the same on every draw, so stars and windows keep their places.
private func noise(_ index: Int, _ salt: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    return Double(x % 10_000) / 10_000
}

// MARK: - Journey

/// A winding road from the start to the goal flag, with the milestones as stations along it.
private struct JourneyArt: View, Animatable {
    var value: Double
    let stations: [(String, Bool)]
    let accent: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 16
            let width = size.width - 2 * inset
            let mid = size.height * 0.46
            let amplitude = min(size.height * 0.22, 26)
            func point(_ t: Double) -> CGPoint {
                CGPoint(x: inset + width * t, y: mid + amplitude * sin(t * .pi * 3))
            }
            var road = Path()
            road.move(to: point(0))
            for step in 1...120 { road.addLine(to: point(Double(step) / 120)) }
            context.stroke(road, with: .color(Theme.ink.opacity(0.14)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            context.stroke(road, with: .color(Theme.ink.opacity(0.28)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 5]))
            let done = clamp(value)
            if done > 0 {
                var travelled = Path()
                travelled.move(to: point(0))
                for step in 1...max(Int(done * 120), 1) { travelled.addLine(to: point(min(Double(step) / 120, done))) }
                travelled.addLine(to: point(done))
                context.stroke(travelled, with: .color(accent), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            // Stations: the milestones, evenly along the way.
            let count = stations.count
            for (index, station) in stations.enumerated() {
                let t = Double(index + 1) / Double(count + 1)
                let p = point(t)
                let reached = station.1 || done >= t
                let r: CGFloat = 5.5
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(reached ? accent : Theme.surface))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(reached ? accent : Theme.ink.opacity(0.35)), lineWidth: 2)
                if size.width / CGFloat(max(count, 1)) > 54 {
                    let text = Text(station.0).font(.system(size: 9.5, weight: .medium)).foregroundStyle(reached ? Theme.textSecondary : Theme.textTertiary)
                    context.draw(text, at: CGPoint(x: p.x, y: p.y + (index % 2 == 0 ? 15 : -15)), anchor: .center)
                }
            }
            // Start and goal.
            let start = point(0)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)), with: .color(Theme.textTertiary))
            let goal = point(1)
            var pole = Path()
            pole.move(to: goal)
            pole.addLine(to: CGPoint(x: goal.x, y: goal.y - 26))
            context.stroke(pole, with: .color(Theme.textSecondary), lineWidth: 1.6)
            for row in 0..<3 {
                for column in 0..<4 {
                    let cell = CGRect(x: goal.x + CGFloat(column) * 4, y: goal.y - 26 + CGFloat(row) * 4, width: 4, height: 4)
                    context.fill(Path(cell), with: .color((row + column) % 2 == 0 ? Theme.textPrimary : (done >= 0.999 ? NoteArtColor.sun : Theme.surface)))
                }
            }
            // The traveller.
            let here = point(done)
            context.fill(Path(ellipseIn: CGRect(x: here.x - 9, y: here.y - 9, width: 18, height: 18)), with: .color(accent.opacity(0.25)))
            context.fill(Path(ellipseIn: CGRect(x: here.x - 6, y: here.y - 6, width: 12, height: 12)), with: .color(accent))
            context.fill(Path(ellipseIn: CGRect(x: here.x - 2.5, y: here.y - 2.5, width: 5, height: 5)), with: .color(.white))
        }
    }
}

// MARK: - Constellation

/// One star per thing to do; the done ones light up and are joined into a figure.
private struct ConstellationArt: View, Animatable {
    var value: Double
    let stars: Int
    let accent: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let sky = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10)
            context.fill(sky, with: .linearGradient(Gradient(colors: [Color(hex: 0x10122A), Color(hex: 0x24204A)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Faint background stars.
            for index in 0..<40 {
                let p = CGPoint(x: noise(index, 7) * size.width, y: noise(index, 11) * size.height)
                context.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.25)))
            }
            let points = (0..<stars).map { index -> CGPoint in
                // Spread over the width in order, so the joined figure reads left to right.
                let x = (Double(index) + 0.5 + (noise(index, 3) - 0.5) * 0.7) / Double(stars)
                let y = 0.18 + noise(index, 5) * 0.64
                return CGPoint(x: x * size.width, y: y * size.height)
            }
            let exact = clamp(value) * Double(stars)
            let lit = Int(exact.rounded(.down))
            var figure = Path()
            for index in 0..<min(lit, stars) {
                if index == 0 { figure.move(to: points[0]) } else { figure.addLine(to: points[index]) }
            }
            if lit < stars, lit > 0 {
                // The line towards the next star grows with the part done.
                let from = points[lit - 1], to = points[lit]
                let part = exact - Double(lit)
                figure.addLine(to: CGPoint(x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part))
            }
            context.stroke(figure, with: .color(accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            for (index, point) in points.enumerated() {
                let on = index < lit
                let radius: CGFloat = on ? 3.4 + CGFloat(noise(index, 9)) * 1.6 : 1.8
                if on {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - radius * 2.4, y: point.y - radius * 2.4, width: radius * 4.8, height: radius * 4.8)), with: .color(accent.opacity(0.22)))
                }
                context.fill(starShape(at: point, radius: radius), with: .color(on ? .white : .white.opacity(0.35)))
            }
        }
    }

    private func starShape(at center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            for step in 0..<8 {
                let angle = Double(step) * .pi / 4 - .pi / 2
                let r = step % 2 == 0 ? radius : radius * 0.38
                let p = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }
}

// MARK: - Hourglass

private struct HourglassArt: View, Animatable {
    var value: Double
    let accent: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let height = min(size.height - 6, size.width * 1.4)
            let width = height * 0.62
            let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
            let neck = CGPoint(x: origin.x + width / 2, y: origin.y + height / 2)
            let sand = NoteArtColor.sun
            let done = clamp(value)
            func top(_ level: Double) -> Path {
                // Sand left in the upper bulb: a triangle shrinking towards the neck.
                let h = height / 2 * 0.86 * CGFloat(level)
                let half = width / 2 * 0.86 * CGFloat(level)
                return Path { path in
                    path.move(to: CGPoint(x: neck.x - half, y: neck.y - h))
                    path.addLine(to: CGPoint(x: neck.x + half, y: neck.y - h))
                    path.addLine(to: CGPoint(x: neck.x, y: neck.y - 2))
                    path.closeSubpath()
                }
            }
            func bottom(_ level: Double) -> Path {
                // Sand in the lower bulb: a heap that grows from the floor.
                let floor = origin.y + height - 4
                let h = height / 2 * 0.8 * CGFloat(level)
                let half = width / 2 * 0.88
                return Path { path in
                    path.move(to: CGPoint(x: neck.x - half, y: floor))
                    path.addLine(to: CGPoint(x: neck.x + half, y: floor))
                    path.addQuadCurve(to: CGPoint(x: neck.x - half, y: floor), control: CGPoint(x: neck.x, y: floor - h * 2))
                    path.closeSubpath()
                }
            }
            if done < 1 { context.fill(top(1 - done), with: .color(sand)) }
            if done > 0 { context.fill(bottom(done), with: .color(sand)) }
            if done > 0.001 && done < 0.999 {
                var stream = Path()
                stream.move(to: neck)
                stream.addLine(to: CGPoint(x: neck.x, y: origin.y + height - 6))
                context.stroke(stream, with: .color(sand.opacity(0.8)), lineWidth: 1.4)
            }
            // The glass.
            let glass = Path { path in
                path.move(to: origin)
                path.addLine(to: CGPoint(x: origin.x + width, y: origin.y))
                path.addCurve(to: CGPoint(x: neck.x + 3, y: neck.y), control1: CGPoint(x: origin.x + width, y: origin.y + height * 0.32), control2: CGPoint(x: neck.x + 3, y: neck.y - height * 0.1))
                path.addCurve(to: CGPoint(x: origin.x + width, y: origin.y + height), control1: CGPoint(x: neck.x + 3, y: neck.y + height * 0.1), control2: CGPoint(x: origin.x + width, y: origin.y + height * 0.68))
                path.addLine(to: CGPoint(x: origin.x, y: origin.y + height))
                path.addCurve(to: CGPoint(x: neck.x - 3, y: neck.y), control1: CGPoint(x: origin.x, y: origin.y + height * 0.68), control2: CGPoint(x: neck.x - 3, y: neck.y + height * 0.1))
                path.addCurve(to: origin, control1: CGPoint(x: neck.x - 3, y: neck.y - height * 0.1), control2: CGPoint(x: origin.x, y: origin.y + height * 0.32))
            }
            context.fill(glass, with: .color(Theme.ink.opacity(0.05)))
            context.stroke(glass, with: .color(Theme.ink.opacity(0.45)), lineWidth: 1.6)
            for y in [origin.y - 2, origin.y + height - 1] {
                context.fill(Path(roundedRect: CGRect(x: origin.x - 6, y: y - 2, width: width + 12, height: 5), cornerRadius: 2), with: .color(accent))
            }
        }
    }
}

// MARK: - Skyline

/// A city at night; its windows light up one after another until the whole skyline glows.
private struct SkylineArt: View, Animatable {
    var value: Double
    let accent: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let sky = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10)
            context.fill(sky, with: .linearGradient(Gradient(colors: [Color(hex: 0x0E1430), accent.opacity(0.55)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let moon = CGRect(x: size.width * 0.82, y: size.height * 0.1, width: 14, height: 14)
            context.fill(Path(ellipseIn: moon), with: .color(NoteArtColor.moonLit))
            context.fill(Path(ellipseIn: moon.offsetBy(dx: 4, dy: -2)), with: .color(Color(hex: 0x0E1430)))
            // Buildings.
            let count = max(6, Int(size.width / 34))
            let slot = size.width / CGFloat(count)
            var windows: [CGRect] = []
            for index in 0..<count {
                let height = size.height * (0.32 + 0.5 * noise(index, 21))
                let width = slot * (0.72 + 0.22 * noise(index, 23))
                let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - height, width: width, height: height)
                context.fill(Path(rect), with: .color(Color(hex: 0x070A18)))
                let columns = max(1, Int(width / 7))
                let rows = max(1, Int((height - 8) / 9))
                for row in 0..<rows {
                    for column in 0..<columns {
                        windows.append(CGRect(x: rect.minX + 3 + CGFloat(column) * ((width - 6) / CGFloat(columns)), y: rect.minY + 5 + CGFloat(row) * 9,
                                              width: max(2, (width - 6) / CGFloat(columns) - 2.5), height: 4.5))
                    }
                }
            }
            // The order the lights go on in, the same on every draw.
            let order = windows.indices.sorted { noise($0, 31) < noise($1, 31) }
            let lit = Int((clamp(value) * Double(windows.count)).rounded())
            for (rank, index) in order.enumerated() {
                let on = rank < lit
                context.fill(Path(windows[index]), with: .color(on ? NoteArtColor.sun.opacity(0.75 + 0.25 * noise(index, 37)) : .white.opacity(0.05)))
            }
        }
    }
}

// MARK: - Picker

/// Every display with a sample; the project's own ones first.
struct ProjectProgressStylePicker: View {
    let selection: ProjectProgressStyle
    let project: Project
    let onPick: (ProjectProgressStyle) -> Void

    var body: some View {
        let sample = NoteProgress(done: 5, total: 8)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 8), count: 4), spacing: 8) {
                ForEach(ProjectProgressStyle.allCases) { style in
                    Button {
                        onPick(style)
                    } label: {
                        VStack(spacing: 4) {
                            ProjectProgressArt(style: style, progress: sample, project: project, accent: project.accent.color)
                                .frame(width: 102, height: 58)
                                .allowsHitTesting(false)
                            Text(style.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(style.tagline)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(7)
                        .frame(width: 118)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style == selection ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style == selection ? Theme.accent : Theme.border, lineWidth: style == selection ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(style.title): \(style.tagline)")
                }
            }
        }
        .frame(height: 300)
    }
}
