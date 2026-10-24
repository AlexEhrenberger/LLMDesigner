import SwiftUI

/// The background menu of a slide: the designs, a colour, a gradient or a picture (from Draw Things or this Mac),
/// for this slide, for every slide of its kind or for the whole presentation.
struct SlideBackgroundPicker: View {
    @Environment(AppModel.self) private var app
    let documentID: WriterDocument.ID
    let slideID: PresentationSlide.ID
    /// Opens the Draw Things sheet (outside this popover).
    let onGenerate: () -> Void
    @State private var scope: Scope?

    enum Scope: Hashable {
        case slide, role, presentation
    }

    private static let swatches: [UInt32] = [0x0C0C0E, 0x1C1C22, 0x14213D, 0x1B4332, 0x3C1053, 0x5C1A1A, 0xF8F5EE, 0xFFFFFF, 0xE9ECEF, 0xFFE8D6, 0xDDEFF7, 0xE8F3E8]

    private static let gradients: [(name: String, colors: [UInt32], angle: Double)] = [
        ("Mitternacht", [0x0F2027, 0x203A43, 0x2C5364], 135),
        ("Tiefsee", [0x000428, 0x004E92], 160),
        ("Brombeere", [0x2B1440, 0x734B6D], 135),
        ("Glut", [0x7A1F0E, 0xF12711, 0xF5AF19], 120),
        ("Lagune", [0x134E5E, 0x71B280], 135),
        ("Lavendel", [0xE0C3FC, 0x8EC5FC], 135),
        ("Pfirsich", [0xFFF1EB, 0xFFD3B6], 160),
        ("Nebel", [0xFFFFFF, 0xE6E9F0], 180),
    ]

    var body: some View {
        if let document = app.document(documentID), let deck = document.deck, let slide = deck.slide(slideID) {
            let current = deck.background(of: slide)
            let scope = scope ?? (slide.background != nil ? .slide : .presentation)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(slide: slide, scope: scope)
                    designs(current: current, role: slide.role, scope: scope)
                    colors(current: current, scope: scope)
                    gradients(current: current, scope: scope)
                    pictures(current: current, slide: slide, scope: scope)
                    footer(slide: slide)
                }
                .padding(16)
            }
            .frame(width: 452, height: 600)
            .background(Theme.surface)
        }
    }

    // MARK: Parts

    private func header(slide: PresentationSlide, scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hintergrund")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Picker("Gilt für", selection: Binding(get: { scope }, set: { self.scope = $0 })) {
                Text("Diese Folie").tag(Scope.slide)
                Text("Alle \(slide.role.plural)").tag(Scope.role)
                Text("Ganze Präsentation").tag(Scope.presentation)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(scopeHint(scope, role: slide.role))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scopeHint(_ scope: Scope, role: SlideRole) -> String {
        switch scope {
        case .slide: "Nur diese Folie bekommt den Hintergrund."
        case .role: "Alle \(role.plural) bekommen ihn, auch neue."
        case .presentation: "Alle Folien bekommen ihn. Ein Design passt sich Titel-, Kapitel- und Inhaltsfolien von selbst an."
        }
    }

    /// The designs in two groups: those that move in the presentation and the still ones.
    private func designs(current: SlideBackground, role: SlideRole, scope: Scope) -> some View {
        let all = SlideDesignLibrary.shared.all
        return section("Designs") {
            VStack(alignment: .leading, spacing: 14) {
                designGroup(all.filter(\.isAnimated), title: "Bewegt", hint: "langsam, nur in der Präsentation", symbol: "wind", current: current, role: role, scope: scope)
                designGroup(all.filter { !$0.isAnimated }, title: "Ruhig", hint: nil, symbol: "square.on.square", current: current, role: role, scope: scope)
            }
        }
    }

    @ViewBuilder
    private func designGroup(_ designs: [SlideDesign], title: String, hint: String?, symbol: String, current: SlideBackground, role: SlideRole, scope: Scope) -> some View {
        if !designs.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                    Text(title).fontWeight(.medium)
                    if let hint { Text("– " + hint) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(designs) { design in
                        let isSelected = current.kind == .design && current.design == design.id
                        Button { apply(.design(design.id), scope: scope) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                SlideBackgroundView(background: .design(design.id), role: role)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .overlay(selectionRing(isSelected))
                                Text(design.name)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(design.summary.isEmpty ? design.name : "\(design.name) – \(design.summary)")
                    }
                }
            }
        }
    }

    private func colors(current: SlideBackground, scope: Scope) -> some View {
        let selected = current.kind == .color ? current.hexColors.first : nil
        return section("Farbe") {
            HStack(spacing: 7) {
                ForEach(Self.swatches, id: \.self) { hex in
                    Button { apply(.color(SlideBackground.string(hex)), scope: scope) } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected == hex ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                ColorPicker("", selection: Binding(
                    get: { Color(hex: selected ?? 0x1C1C22) },
                    set: { apply(.color(SlideBackground.string($0.hexValue)), scope: scope) }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Eigene Farbe")
            }
        }
    }

    private func gradients(current: SlideBackground, scope: Scope) -> some View {
        let isGradient = current.kind == .gradient
        return section("Verlauf") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Self.gradients, id: \.name) { preset in
                        let background = SlideBackground.gradient(preset.colors.map(SlideBackground.string), angle: preset.angle)
                        let isSelected = isGradient && current.hexColors == preset.colors
                        Button { apply(background, scope: scope) } label: {
                            SlideBackgroundView(background: background, role: .content)
                                .frame(height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(selectionRing(isSelected))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
                if isGradient {
                    gradientEditor(current, scope: scope)
                }
            }
        }
    }

    /// The open gradient's colours, direction and form.
    private func gradientEditor(_ current: SlideBackground, scope: Scope) -> some View {
        let colors = current.hexColors.count >= 2 ? current.hexColors : [0x0F2027, 0x2C5364]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(colors.indices, id: \.self) { index in
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: colors[index]) },
                        set: { color in
                            var changed = current
                            var list = colors
                            list[index] = color.hexValue
                            changed.colors = list.map(SlideBackground.string)
                            apply(changed, scope: scope)
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                Spacer()
                Toggle("Kreisförmig", isOn: Binding(get: { current.radial == true }, set: { radial in
                    var changed = current
                    changed.radial = radial ? true : nil
                    apply(changed, scope: scope)
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }
            if current.radial != true {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees((current.angle ?? 135) - 45))
                    Slider(value: Binding(get: { current.angle ?? 135 }, set: { angle in
                        var changed = current
                        changed.angle = (angle / 5).rounded() * 5
                        apply(changed, scope: scope)
                    }), in: 0...360)
                    .controlSize(.small)
                    Text("\(Int(current.angle ?? 135))°")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func pictures(current: SlideBackground, slide: PresentationSlide, scope: Scope) -> some View {
        section("Bild") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    wideButton("Mit Draw Things generieren …", symbol: "wand.and.stars") { onGenerate() }
                        .help("Die KI beschreibt das Bild, Draw Things malt es – je ein Bild für Titel-, Kapitel- und Inhaltsfolien oder eines für diese Folie")
                    wideButton("Bild wählen …", symbol: "photo") {
                        app.chooseBackgroundImage(for: documentID) { apply($0, scope: scope) }
                    }
                }
                if current.kind == .image {
                    imageEditor(current, role: slide.role, scope: scope)
                }
            }
        }
    }

    /// How much the picture is darkened and which colour the text has.
    private func imageEditor(_ current: SlideBackground, role: SlideRole, scope: Scope) -> some View {
        let tone = SlideLook.tone(of: current, role: role)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tone == .light ? "Abdunkeln" : "Aufhellen")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { current.dim ?? 0 }, set: { value in
                    var changed = current
                    changed.dim = (value * 20).rounded() / 20
                    apply(changed, scope: scope)
                }), in: 0...0.8)
                .controlSize(.small)
                Text("\(Int(((current.dim ?? 0) * 100).rounded())) %")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("Schrift")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Picker("", selection: Binding(get: { tone }, set: { newTone in
                    var changed = current
                    changed.tone = newTone
                    apply(changed, scope: scope)
                })) {
                    Text("Hell").tag(SlideTone.light)
                    Text("Dunkel").tag(SlideTone.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func footer(slide: PresentationSlide) -> some View {
        HStack(spacing: 10) {
            if slide.background != nil {
                Button("Hintergrund der Präsentation verwenden") { app.setSlideBackground(documentID, slideID, nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            Spacer()
            Button {
                SlideDesignLibrary.shared.revealUserFolder()
            } label: {
                Label("Eigene Designs …", systemImage: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.link)
            .help("Öffnet den Ordner der Bibliothek für eigene Designs (CSS); die Anleitung liegt darin")
        }
    }

    // MARK: Helpers

    private func apply(_ background: SlideBackground, scope: Scope) {
        guard let slide = app.document(documentID)?.deck?.slide(slideID) else { return }
        switch scope {
        case .slide: app.setSlideBackground(documentID, slideID, background)
        case .role: app.setRoleBackground(documentID, slide.role, background)
        case .presentation: app.setPresentationBackground(documentID, background)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            content()
        }
    }

    private func selectionRing(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
    }

    private func wideButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    /// The colour as `0xRRGGBB` in sRGB.
    var hexValue: UInt32 {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
    }
}

// MARK: Draw Things

/// Pictures for the backgrounds from Draw Things: the model describes them from the topic, one per kind of slide
/// (or one for this slide), and Draw Things paints them in the background.
struct SlideBackgroundGeneratorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let documentID: WriterDocument.ID
    let slideID: PresentationSlide.ID
    @State private var description = ""
    @State private var style: ImageStyle = .automatic
    @State private var tone: SlideTone = .light
    @State private var onlyThisSlide = false
    @State private var roles: Set<SlideRole> = Set(SlideRole.allCases)
    @State private var resolution: ImageResolution = .standard
    @State private var status: String?
    @State private var drawThings: Bool?
    @State private var progress: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let slideRole = app.document(documentID)?.deck?.slide(slideID)?.role ?? .content
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hintergrund mit Draw Things")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Das Sprachmodell beschreibt das Bild, Draw Things malt es mit Qwen Image.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Thema oder Bildidee")
                TextField("z. B. „Wald im Morgennebel“ – leer: passend zum Titel der Präsentation", text: $description, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Stil")
                    Picker("", selection: $style) {
                        ForEach(ImageStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("Helligkeit")
                    Picker("", selection: $tone) {
                        Text("Dunkel, helle Schrift").tag(SlideTone.light)
                        Text("Hell, dunkle Schrift").tag(SlideTone.dark)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Für")
                Picker("", selection: $onlyThisSlide) {
                    Text("Die Präsentation – je ein Bild").tag(false)
                    Text("Nur diese Folie (\(slideRole.label))").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !onlyThisSlide {
                    HStack(spacing: 16) {
                        ForEach(SlideRole.allCases) { role in
                            Toggle(role.plural, isOn: Binding(
                                get: { roles.contains(role) },
                                set: { if $0 { roles.insert(role) } else { roles.remove(role) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 20)
                    .font(.system(size: 12.5))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Qualität")
                Picker("", selection: $resolution) {
                    ForEach(ImageResolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 280)
                Text("Ein Bild in Standardqualität dauert auf diesem Mac etwa 2–3 Minuten. Die Bilder entstehen im Hintergrund; bis dahin zeigen die Folien einen Platzhalter.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if drawThings == false {
                Label(status ?? "Draw Things ist nicht erreichbar. Starte Draw Things und schalte dort die HTTP-API ein.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Abbrechen") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(onlyThisSlide || roles.count == 1 ? "Bild generieren" : "\(roles.count) Bilder generieren") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress != nil || drawThings != true || (!onlyThisSlide && roles.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
        .task {
            // Checked again every few seconds while Draw Things isn't there, so starting it is noticed.
            while !Task.isCancelled {
                do {
                    _ = try await app.imageGeneration.client?.status()
                    drawThings = app.imageGeneration.client != nil
                    if drawThings == true { break }
                } catch {
                    drawThings = false
                    status = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onAppear {
            resolution = app.imageGeneration.defaults.resolution
            style = app.imageGeneration.defaults.style
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
    }

    private func start() {
        let request = SlideBackgroundRequest(
            description: description,
            style: style,
            tone: tone,
            roles: SlideRole.allCases.filter { roles.contains($0) },
            slideID: onlyThisSlide ? slideID : nil,
            resolution: resolution
        )
        error = nil
        progress = "Das Modell beschreibt das Bild …"
        task = Task {
            do {
                try await app.generateSlideBackgrounds(documentID, request) { progress = $0 }
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            progress = nil
        }
    }
}
