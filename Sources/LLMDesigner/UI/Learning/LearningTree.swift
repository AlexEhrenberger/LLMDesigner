import SwiftUI

/// A discipline's tree, drawn from its growth: a sprout at first, then a trunk with more and more branches; leaves
/// for known cards, blossoms for learning steadily, fruits for finished courses and good quizzes. The same
/// discipline always grows the same tree (its id seeds the shape), and it sways a little in the wind.
struct LearningTreeView: View {
    let growth: TreeGrowth
    let kind: TreeKind
    let color: FolderColor
    let seed: UInt64
    var sways = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if sways && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: 0)
        }
    }

    private func canvas(time: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            TreePainter(growth: growth, kind: kind, accent: Color(hex: color.hex), seed: seed, time: time).draw(in: &context, size: size)
        }
    }
}

/// A small deterministic random source (SplitMix64), so a tree keeps its shape between drawings.
struct TreeRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
}

private struct TreePainter {
    let growth: TreeGrowth
    let kind: TreeKind
    let accent: Color
    let seed: UInt64
    let time: Double

    struct Tip {
        var point: CGPoint
        var angle: Double
        var depth: Int
    }

    /// How a kind of tree branches.
    struct Shape {
        var spread: Double
        var children: Int
        var ratio: Double
        var upward: Double
        var trunk: Double
        var leaf: Color
        var leafAlt: Color
        var blossom: Color
        var bark: Color
        var barkLight: Color
    }

    var shape: Shape {
        switch kind {
        case .eiche:
            return Shape(spread: 0.62, children: 3, ratio: 0.74, upward: 0.08, trunk: 1.15, leaf: Color(hex: 0x3E9B4F), leafAlt: Color(hex: 0x6CC36A),
                         blossom: accent, bark: Color(hex: 0x5B3A24), barkLight: Color(hex: 0x7A5233))
        case .kirsche:
            return Shape(spread: 0.55, children: 2, ratio: 0.76, upward: 0.05, trunk: 1.0, leaf: Color(hex: 0x58A85A), leafAlt: Color(hex: 0x8FCB78),
                         blossom: Color(hex: 0xF6A6C8), bark: Color(hex: 0x4A2E25), barkLight: Color(hex: 0x6E4537))
        case .ahorn:
            return Shape(spread: 0.5, children: 3, ratio: 0.72, upward: 0.12, trunk: 1.05, leaf: Color(hex: 0xD9622B), leafAlt: Color(hex: 0xF2A33A),
                         blossom: Color(hex: 0xFFD45A), bark: Color(hex: 0x553626), barkLight: Color(hex: 0x76503A))
        case .birke:
            return Shape(spread: 0.44, children: 2, ratio: 0.8, upward: 0.28, trunk: 0.75, leaf: Color(hex: 0x9CCB4B), leafAlt: Color(hex: 0xC9E27A),
                         blossom: accent, bark: Color(hex: 0xE9E4DA), barkLight: Color(hex: 0xFFFFFF))
        case .kiefer:
            return Shape(spread: 0.95, children: 2, ratio: 0.7, upward: 0.0, trunk: 1.0, leaf: Color(hex: 0x2F6E4A), leafAlt: Color(hex: 0x4C8F62),
                         blossom: Color(hex: 0xC8E6A0), bark: Color(hex: 0x4E3324), barkLight: Color(hex: 0x6B4A35))
        case .magnolie:
            return Shape(spread: 0.7, children: 2, ratio: 0.75, upward: 0.04, trunk: 0.95, leaf: Color(hex: 0x4F9A62), leafAlt: Color(hex: 0x7DBE84),
                         blossom: Color(hex: 0xF3D2E6), bark: Color(hex: 0x5E4A44), barkLight: Color(hex: 0x86706A))
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let groundY = size.height * 0.9
        drawGround(&context, size: size, groundY: groundY)
        let stage = max(0.03, min(1, growth.stage))
        if stage < 0.1 {
            drawSprout(&context, base: CGPoint(x: size.width / 2, y: groundY), size: size, stage: stage)
            return
        }
        let s = shape
        var random = TreeRandom(seed: seed)
        let maxDepth = 2.0 + stage * 7.2
        let depthLimit = Int(ceil(maxDepth))
        let scale = min(size.width * 0.9, size.height)
        let trunkLength = scale * (0.09 + 0.12 * stage) * s.trunk
        let trunkWidth = scale * (0.018 + 0.045 * stage)
        var tips: [Tip] = []
        var segments = 0

        func sway(_ depth: Int, _ salt: Double) -> Double {
            guard time != 0 else { return 0 }
            return sin(time * 0.9 + Double(depth) * 0.7 + salt) * 0.012 * Double(depth + 1) * (0.6 + stage * 0.4)
        }

        func branch(from start: CGPoint, angle: Double, length: Double, width: Double, depth: Int) {
            segments += 1
            guard segments < 2_600 else { return }
            let partial = Double(depth) + 1 > maxDepth ? max(0.15, maxDepth - Double(depth)) : 1
            let bent = angle + sway(depth, Double(seed % 97))
            let end = CGPoint(x: start.x + cos(bent) * length * partial, y: start.y - sin(bent) * length * partial)
            var path = Path()
            path.move(to: start)
            // A slight curve makes the branch look grown, not drawn with a ruler.
            let mid = CGPoint(x: (start.x + end.x) / 2 + CGFloat(random.range(-0.06, 0.06) * length), y: (start.y + end.y) / 2)
            path.addQuadCurve(to: end, control: mid)
            let barkColor = depth < 2 ? s.bark : s.barkLight
            context.stroke(path, with: .color(barkColor), style: StrokeStyle(lineWidth: max(0.6, width * partial.squareRoot()), lineCap: .round))
            if kind == .birke, depth < 2, width > 4 {
                // Birch bark: dark marks across the white.
                for _ in 0..<Int(length / 14) {
                    let t = random.range(0.1, 0.9)
                    let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    var mark = Path()
                    mark.move(to: CGPoint(x: p.x - width * 0.35, y: p.y))
                    mark.addLine(to: CGPoint(x: p.x + width * 0.2, y: p.y - 1))
                    context.stroke(mark, with: .color(Color(hex: 0x3A3A3A).opacity(0.7)), lineWidth: 1.4)
                }
            }
            if depth + 1 >= depthLimit || partial < 1 || length < 2.5 {
                tips.append(Tip(point: end, angle: bent, depth: depth))
                return
            }
            // Leaves also sit along the outer branches, not only at their ends.
            if Double(depth) > maxDepth - 3 { tips.append(Tip(point: end, angle: bent, depth: depth)) }
            let count = depth < 3 ? s.children : min(s.children, 2)
            for index in 0..<count {
                var offset: Double
                if count == 1 {
                    offset = 0
                } else {
                    offset = (Double(index) / Double(count - 1) - 0.5) * 2 * s.spread
                }
                offset += random.range(-0.14, 0.14)
                var childAngle = bent + offset
                // Pull towards the sky (birch) or flatten (pine).
                childAngle += (Double.pi / 2 - childAngle) * s.upward
                if kind == .kiefer {
                    // A pine keeps a leader and sends side branches out flat.
                    childAngle = index == 0 ? bent + random.range(-0.05, 0.05) : (index % 2 == 0 ? 0.25 : Double.pi - 0.25) + random.range(-0.2, 0.2)
                }
                let ratio = s.ratio * random.range(0.9, 1.08) * (kind == .kiefer && index > 0 ? 0.72 : 1)
                branch(from: end, angle: childAngle, length: length * ratio, width: width * 0.68, depth: depth + 1)
            }
        }

        let base = CGPoint(x: size.width / 2, y: groundY)
        if kind == .kiefer {
            tips = conifer(&context, base: base, scale: scale, stage: stage, random: &random)
        } else {
            branch(from: base, angle: Double.pi / 2 + random.range(-0.04, 0.04), length: trunkLength, width: trunkWidth, depth: 0)
        }
        drawCanopy(&context, tips: tips, scale: scale, stage: stage)
        drawLeaves(&context, tips: tips, scale: scale, stage: stage, random: &random)
        drawBlossoms(&context, tips: tips, scale: scale, random: &random)
        drawFruits(&context, tips: tips, scale: scale, random: &random)
    }

    /// A pine: a straight trunk with whorls of branches that get shorter towards the top, a cone of needles.
    private func conifer(_ context: inout GraphicsContext, base: CGPoint, scale: Double, stage: Double, random: inout TreeRandom) -> [Tip] {
        let s = shape
        let height = scale * (0.22 + 0.5 * stage)
        let width = scale * (0.012 + 0.03 * stage)
        let swing = time == 0 ? 0 : sin(time * 0.8) * 1.5 * stage
        let top = CGPoint(x: base.x + swing, y: base.y - height)
        var trunk = Path()
        trunk.move(to: base)
        trunk.addLine(to: top)
        context.stroke(trunk, with: .color(s.bark), style: StrokeStyle(lineWidth: width, lineCap: .round))
        var tips: [Tip] = [Tip(point: top, angle: Double.pi / 2, depth: 6)]
        let tiers = 3 + Int(stage * 9)
        for tier in 0..<tiers {
            let t = 0.18 + 0.8 * Double(tier) / Double(tiers)
            let y = base.y - height * t
            let x = base.x + swing * t
            let length = (1 - t) * scale * (0.07 + 0.2 * stage) + 4
            for side in [-1.0, 1.0] {
                let droop = random.range(0.12, 0.3)
                let angle = side < 0 ? Double.pi + droop : -droop
                let bend = time == 0 ? 0 : sin(time * 0.9 + Double(tier)) * 0.02
                let end = CGPoint(x: x + cos(angle + bend) * length, y: y - sin(angle + bend) * length)
                var branch = Path()
                branch.move(to: CGPoint(x: x, y: y))
                branch.addLine(to: end)
                context.stroke(branch, with: .color(s.barkLight), style: StrokeStyle(lineWidth: max(0.8, width * 0.35 * (1 - t) + 0.8), lineCap: .round))
                // Needles all along the branch.
                let count = max(2, Int(length / 7))
                for step in 1...count {
                    let f = Double(step) / Double(count)
                    tips.append(Tip(point: CGPoint(x: x + (end.x - x) * f, y: y + (end.y - y) * f), angle: angle, depth: 6))
                }
            }
        }
        return tips
    }

    /// A soft shadowed crown behind the leaves, so a grown tree looks full and not like dots.
    private func drawCanopy(_ context: inout GraphicsContext, tips: [Tip], scale: Double, stage: Double) {
        guard growth.leaves > 0.3, stage > 0.25, !tips.isEmpty, kind != .kiefer else { return }
        let s = shape
        let radius = scale * (0.03 + 0.03 * stage)
        var shade = context
        shade.opacity = 0.32 * growth.leaves
        for (index, tip) in tips.enumerated() where index % 2 == 0 {
            shade.fill(Path(ellipseIn: CGRect(x: tip.point.x - radius, y: tip.point.y - radius * 0.8, width: radius * 2, height: radius * 1.6)),
                       with: .color(s.leaf.opacity(0.9)))
        }
    }

    private func drawGround(_ context: inout GraphicsContext, size: CGSize, groundY: CGFloat) {
        var mound = Path()
        mound.addEllipse(in: CGRect(x: size.width * 0.12, y: groundY - size.height * 0.035, width: size.width * 0.76, height: size.height * 0.12))
        context.fill(mound, with: .linearGradient(Gradient(colors: [Color(hex: 0x5FAE57), Color(hex: 0x2F6B3A)]),
                                                  startPoint: CGPoint(x: size.width / 2, y: groundY - size.height * 0.03),
                                                  endPoint: CGPoint(x: size.width / 2, y: groundY + size.height * 0.08)))
        // Grass blades and, with steady learning, little flowers.
        var random = TreeRandom(seed: seed &+ 7)
        for _ in 0..<40 {
            let x = random.range(0.16, 0.84) * size.width
            let height = random.range(4, 10)
            var blade = Path()
            blade.move(to: CGPoint(x: x, y: groundY + 2))
            blade.addLine(to: CGPoint(x: x + random.range(-2, 2), y: groundY - height))
            context.stroke(blade, with: .color(Color(hex: 0x7CC46B).opacity(0.8)), lineWidth: 1)
        }
        let flowers = Int(growth.blossoms * 12)
        for _ in 0..<flowers {
            let center = CGPoint(x: random.range(0.18, 0.82) * size.width, y: groundY + random.range(-2, 6))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(accent.opacity(0.9)))
        }
    }

    private func drawSprout(_ context: inout GraphicsContext, base: CGPoint, size: CGSize, stage: Double) {
        let height = size.height * (0.08 + stage * 0.9)
        var stem = Path()
        stem.move(to: base)
        let swing = time == 0 ? 0 : sin(time * 1.2) * 2
        stem.addQuadCurve(to: CGPoint(x: base.x + swing, y: base.y - height), control: CGPoint(x: base.x - 6, y: base.y - height / 2))
        context.stroke(stem, with: .color(Color(hex: 0x4E9A45)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        let top = CGPoint(x: base.x + swing, y: base.y - height)
        for side in [-1.0, 1.0] {
            var leaf = Path()
            leaf.move(to: top)
            leaf.addQuadCurve(to: CGPoint(x: top.x + side * 16, y: top.y - 6), control: CGPoint(x: top.x + side * 8, y: top.y - 14))
            leaf.addQuadCurve(to: top, control: CGPoint(x: top.x + side * 10, y: top.y + 2))
            context.fill(leaf, with: .color(Color(hex: 0x6CC36A)))
        }
    }

    private func drawLeaves(_ context: inout GraphicsContext, tips: [Tip], scale: Double, stage: Double, random: inout TreeRandom) {
        let s = shape
        let density = 0.25 + 0.75 * growth.leaves
        let size = scale * (0.016 + 0.012 * stage)
        for tip in tips where random.next() < density {
            let cluster = kind == .kiefer ? 5 : 3 + Int(growth.leaves * 3)
            for _ in 0..<cluster {
                let dx = random.range(-1.6, 1.6) * size
                let dy = random.range(-1.4, 1.0) * size
                let center = CGPoint(x: tip.point.x + dx, y: tip.point.y + dy)
                let tint = random.next() < 0.5 ? s.leaf : s.leafAlt
                if kind == .kiefer {
                    // Needles: short dark strokes.
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: CGPoint(x: center.x + random.range(-1, 1) * size, y: center.y + size * 0.6))
                    context.stroke(needle, with: .color(tint), lineWidth: 1.6)
                } else {
                    let rect = CGRect(x: center.x - size * 0.6, y: center.y - size * 0.42, width: size * 1.2, height: size * 0.84)
                    var leaf = context
                    leaf.translateBy(x: rect.midX, y: rect.midY)
                    leaf.rotate(by: .radians(random.range(-1.2, 1.2)))
                    leaf.fill(Path(ellipseIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)),
                              with: .color(tint.opacity(0.92)))
                }
            }
        }
    }

    private func drawBlossoms(_ context: inout GraphicsContext, tips: [Tip], scale: Double, random: inout TreeRandom) {
        guard growth.blossoms > 0.02 else { return }
        let s = shape
        let size = scale * 0.011
        let richness = kind == .kirsche || kind == .magnolie ? 0.8 : 0.5
        for tip in tips where random.next() < growth.blossoms * richness {
            let center = CGPoint(x: tip.point.x + random.range(-1, 1) * size * 2, y: tip.point.y + random.range(-1, 1) * size * 2)
            for petal in 0..<5 {
                let angle = Double(petal) / 5 * 2 * Double.pi + random.range(0, 0.3)
                let p = CGPoint(x: center.x + cos(angle) * size * 0.8, y: center.y + sin(angle) * size * 0.8)
                context.fill(Path(ellipseIn: CGRect(x: p.x - size * 0.55, y: p.y - size * 0.55, width: size * 1.1, height: size * 1.1)),
                             with: .color(s.blossom.opacity(0.95)))
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - size * 0.35, y: center.y - size * 0.35, width: size * 0.7, height: size * 0.7)),
                         with: .color(Color(hex: 0xFFE27A)))
        }
    }

    private func drawFruits(_ context: inout GraphicsContext, tips: [Tip], scale: Double, random: inout TreeRandom) {
        guard growth.fruits > 0, !tips.isEmpty else { return }
        let size = scale * 0.02
        let colors = [Color(hex: 0xE8503A), Color(hex: 0xF2B23E), accent]
        for index in 0..<growth.fruits {
            let tip = tips[Int(random.next() * Double(tips.count)) % tips.count]
            let center = CGPoint(x: tip.point.x, y: tip.point.y + size * 0.9)
            var stem = Path()
            stem.move(to: tip.point)
            stem.addLine(to: CGPoint(x: center.x, y: center.y - size * 0.5))
            context.stroke(stem, with: .color(Color(hex: 0x5B3A24)), lineWidth: 1)
            let fruit = Path(ellipseIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            context.fill(fruit, with: .color(colors[index % colors.count]))
            context.fill(Path(ellipseIn: CGRect(x: center.x - size * 0.25, y: center.y - size * 0.3, width: size * 0.25, height: size * 0.2)), with: .color(.white.opacity(0.5)))
        }
    }
}

/// The sky behind the garden follows the time of day: morning gold, day blue, evening rose, night deep blue.
struct GardenSky: View {
    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let colors: [Color] = switch hour {
        case 5..<9: [Color(hex: 0xFBD3A2), Color(hex: 0xBFE0F0)]
        case 9..<17: [Color(hex: 0x8CC8F0), Color(hex: 0xDDF1FB)]
        case 17..<21: [Color(hex: 0xF4A28C), Color(hex: 0xC9B6E8)]
        default: [Color(hex: 0x1B2650), Color(hex: 0x3B4C84)]
        }
        ZStack(alignment: .bottom) {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            if hour < 5 || hour >= 21 {
                Canvas { context, size in
                    var random = TreeRandom(seed: 42)
                    for _ in 0..<60 {
                        let point = CGPoint(x: random.next() * size.width, y: random.next() * size.height * 0.6)
                        let r = random.range(0.5, 1.6)
                        context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: r, height: r)), with: .color(.white.opacity(random.range(0.4, 0.9))))
                    }
                }
            }
            Canvas { context, size in
                // Two rows of soft hills.
                for (index, tint) in [Color(hex: 0x9ACD8A).opacity(0.7), Color(hex: 0x6DAF68).opacity(0.85)].enumerated() {
                    var hills = Path()
                    let base = size.height * (index == 0 ? 0.72 : 0.84)
                    hills.move(to: CGPoint(x: 0, y: size.height))
                    hills.addLine(to: CGPoint(x: 0, y: base))
                    let steps = 6
                    for step in 0...steps {
                        let x = size.width * CGFloat(step) / CGFloat(steps)
                        let y = base - CGFloat(sin(Double(step) * 1.3 + Double(index)) * 18 + 10)
                        hills.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - size.width / CGFloat(steps * 2), y: y - 16))
                    }
                    hills.addLine(to: CGPoint(x: size.width, y: size.height))
                    hills.closeSubpath()
                    context.fill(hills, with: .color(tint))
                }
            }
        }
    }
}

extension UUID {
    /// A stable number from the id (for a tree's shape).
    var treeSeed: UInt64 {
        withUnsafeBytes(of: uuid) { raw in raw.load(as: UInt64.self) }
    }
}
