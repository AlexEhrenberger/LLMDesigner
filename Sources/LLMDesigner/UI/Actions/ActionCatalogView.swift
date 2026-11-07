import SwiftUI
import LLMDProtocol

enum ActionCatalogWindow {
    static let id = "action-catalog"
}

/// A plain overview of what agents can do: every action of the registry by module, with its parameters, its
/// safety properties and an example call. It only reads the descriptors; nothing here runs an action.
struct ActionCatalogView: View {
    @State private var module: String?
    @State private var query = ""
    @State private var selection: String?

    private var descriptors: [ActionDescriptor] { ActionHub.shared?.registry.descriptors ?? ActionRegistry.standard().descriptors }

    var body: some View {
        let all = descriptors
        let modules = Dictionary(grouping: all, by: \.module).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
        let shown = all.filter { (module == nil || $0.module == module) && Self.matches($0, query) }

        HSplitView {
            List(selection: $module) {
                Label("Alle", systemImage: "square.grid.2x2")
                    .badge(all.count)
                    .tag(String?.none)
                Section("Module") {
                    ForEach(modules, id: \.0) { name, count in
                        Label(Self.moduleTitle(name), systemImage: Self.moduleSymbol(name))
                            .badge(count)
                            .tag(String?.some(name))
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)

            VStack(spacing: 0) {
                TextField("Actions durchsuchen", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(shown, id: \.id, selection: $selection) { descriptor in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(descriptor.id)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer(minLength: 4)
                            KindBadge(kind: descriptor.kind)
                        }
                        Text(descriptor.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
                .overlay {
                    if shown.isEmpty { Text("Keine Treffer").foregroundStyle(.secondary) }
                }
            }
            .frame(minWidth: 300, idealWidth: 380)

            Group {
                if let id = selection, let descriptor = all.first(where: { $0.id == id }) {
                    ActionCatalogDetail(descriptor: descriptor)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Eine Action wählen")
                            .foregroundStyle(.secondary)
                        Text("Alle Actions sind über llmd und MCP erreichbar, ein Minimalsatz auch im Chat.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, idealWidth: 420)
        }
        .frame(minWidth: 860, minHeight: 420)
    }

    static func matches(_ descriptor: ActionDescriptor, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || descriptor.id.localizedStandardContains(query) || descriptor.summary.localizedStandardContains(query)
    }

    static func moduleTitle(_ module: String) -> String {
        switch module {
        case "writer": "Writer Studio"
        case "presenter": "Presenter Studio"
        case "citation": "Citation Studio"
        case "stories": "Stories Studio"
        case "chat": "Chats"
        case "minichat": "Mini-Chat"
        case "persona": "Personas"
        case "skill": "Skills"
        case "memory": "Gedächtnis"
        case "folder": "Ordner"
        case "library": "Bibliothek"
        case "models": "Modelle"
        case "connection": "Verbindung"
        case "view": "Ansicht"
        case "actions": "Actions"
        case "app": "App"
        default: module.capitalized
        }
    }

    static func moduleSymbol(_ module: String) -> String {
        switch module {
        case "writer": StudioApplication.writer.symbol
        case "presenter": StudioApplication.presenter.symbol
        case "citation": "quote.opening"
        case "stories": "book.closed"
        case "chat", "minichat": "bubble.left.and.bubble.right"
        case "persona": Persona.symbol
        case "skill": Skill.defaultSymbol
        case "memory": "brain"
        case "folder": "folder"
        case "library": "books.vertical"
        case "models", "connection": "cpu"
        case "view": "eye"
        default: "gearshape"
        }
    }
}

private struct KindBadge: View {
    let kind: ActionKind

    var body: some View {
        Text(kind.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch kind {
        case .read: .secondary
        case .write: Theme.accent
        case .destructive: .red
        }
    }
}

/// One action: what it does, how the safety rule sees it, its parameters and how to call it.
struct ActionCatalogDetail: View {
    let descriptor: ActionDescriptor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.id)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(descriptor.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    KindBadge(kind: descriptor.kind)
                    if descriptor.security.readsUntrusted { tag("liest Fremdes (A)", .orange) }
                    if descriptor.security.sensitive { tag("sensibel (B)", .orange) }
                    tag(Self.effect(descriptor.security.effect), .secondary)
                }
                section("Parameter") {
                    let properties = (descriptor.input.properties ?? [:]).sorted { lhs, rhs in
                        let required = descriptor.input.required ?? []
                        let l = required.firstIndex(of: lhs.key) ?? Int.max, r = required.firstIndex(of: rhs.key) ?? Int.max
                        return l == r ? lhs.key < rhs.key : l < r
                    }
                    if properties.isEmpty {
                        Text("Keine").foregroundStyle(.secondary)
                    }
                    ForEach(properties, id: \.key) { name, schema in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(Self.typeName(schema)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if descriptor.input.required?.contains(name) == true {
                                    Text("Pflicht").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            if let text = schema.description, !text.isEmpty {
                                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            if let values = schema.enumValues ?? schema.items?.enumValues {
                                Text(values.joined(separator: " · "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                section("Aufruf im Terminal") {
                    Text(descriptor.example ?? Self.command(descriptor))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
                if !descriptor.groups.isEmpty {
                    section("Gruppen und MCP-Profile") {
                        Text(descriptor.groups.joined(separator: ", "))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    /// The command `llmd` makes from the id: dots become words, camelCase becomes kebab-case, required parameters follow.
    static func command(_ descriptor: ActionDescriptor) -> String {
        let words = descriptor.id.split(separator: ".").map { part in
            part.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
        }
        let required = (descriptor.input.required ?? []).map { "<\($0)>" }
        return (["llmd"] + words + required).joined(separator: " ")
    }

    static func effect(_ effect: ActionEffect) -> String {
        switch effect {
        case .none: "keine Wirkung"
        case .local: "ändert lokal"
        case .destructive: "zerstört"
        case .outbound: "wirkt nach außen"
        }
    }

    static func typeName(_ schema: JSONSchema) -> String {
        switch schema.type {
        case "string": schema.enumValues == nil ? "Text" : "Auswahl"
        case "boolean": "ja/nein"
        case "integer": "Zahl"
        case "number": "Zahl"
        case "array": "Liste"
        case "object": "Objekt"
        default: "beliebig"
        }
    }
}
