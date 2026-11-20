import AppKit
import SwiftUI

/// The colours of FinanceStudio's charts. Income and expenses are the two poles of one scale (blue and red, the
/// diverging pair), each stepped for its appearance; the four parts of the monthly budget are the first four
/// categorical slots in their fixed order. Text never wears these colours: a swatch beside it carries the identity.
enum FinanceColors {
    static let income = Theme.dynamic(dark: 0x3987E5, light: 0x2A78D6)
    static let expense = Theme.dynamic(dark: 0xE66767, light: 0xE34948)
    static let slots = [
        Theme.dynamic(dark: 0x3987E5, light: 0x2A78D6),
        Theme.dynamic(dark: 0xD95926, light: 0xEB6834),
        Theme.dynamic(dark: 0x199E70, light: 0x1BAF7A),
        Theme.dynamic(dark: 0xC98500, light: 0xEDA100),
    ]
    /// "Delta up good" as text: income amounts in the table.
    static let positiveText = Theme.dynamic(dark: 0x0CA30C, light: 0x006300)
    static let grid = Theme.dynamic(dark: 0x2C2C2A, light: 0xE1E0D9)
    static let baseline = Theme.dynamic(dark: 0x383835, light: 0xC3C2B7)
    static let meterTrack = Theme.dynamic(dark: 0x2C2C2A, light: 0xE6ECF5)
}

/// An amount as text: income with a plus in the success ink, expenses in the primary ink, hidden as dots on request.
struct FinanceAmount: View {
    @Environment(AppModel.self) private var app
    let cents: Int
    var size: CGFloat = 12.5
    var weight: Font.Weight = .medium
    var sign = true
    var colored = true

    var body: some View {
        Text(app.finance.format(cents, sign: sign))
            .font(.system(size: size, weight: weight).monospacedDigit())
            .foregroundStyle(colored && cents > 0 && !app.finance.state.hidesAmounts ? FinanceColors.positiveText : Theme.textPrimary)
            .lineLimit(1)
    }
}

/// A headline number with its label: income, expenses, what is free.
struct FinanceStatTile: View {
    @Environment(AppModel.self) private var app
    let title: String
    let cents: Int
    var sign = false
    var swatch: Color?
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(swatch).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Text(app.finance.format(cents, sign: sign))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// How full something is: a track and a fill of the same hue.
struct FinanceMeter: View {
    let progress: Double
    var color: Color = FinanceColors.income
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(FinanceColors.meterTrack)
                Capsule().fill(color).frame(width: max(progress > 0 ? height : 0, geometry.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((progress * 100).rounded())) Prozent")
    }
}

/// A category as a small chip with its symbol.
struct FinanceCategoryChip: View {
    let category: FinanceCategory?
    var source: FinanceCategorySource = .keyword

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: category?.symbol ?? "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(category?.color.color ?? Theme.textTertiary)
            Text(category?.name ?? "Ohne Kategorie")
                .font(.system(size: 11.5))
                .foregroundStyle(category == nil ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(1)
            if source == .model {
                Image(systemName: "sparkles")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Vom Modell vorgeschlagen")
            }
        }
    }
}

/// The categories as menu items, grouped by kind; only those that fit the sign when one is given.
struct FinanceCategoryItems: View {
    let categories: [FinanceCategory]
    var cents: Int?
    var none: String? = "Keine Kategorie"
    let pick: (String?) -> Void

    var body: some View {
        ForEach(FinanceCategory.Kind.allCases) { kind in
            let members = categories.filter { $0.kind == kind && (cents.map(kind.fits) ?? true) }
            if !members.isEmpty {
                Section(kind == .expense ? "Ausgaben" : kind == .income ? "Einnahmen" : "Umbuchungen") {
                    ForEach(members) { category in
                        Button(category.name, systemImage: category.symbol) { pick(category.key) }
                    }
                }
            }
        }
        if let none {
            Divider()
            Button(none, systemImage: "xmark.circle") { pick(nil) }
        }
    }
}

/// A text field for an amount in German writing; it takes the value when the person leaves it or presses Return.
struct FinanceAmountField: View {
    let placeholder: String
    @Binding var cents: Int?
    var width: CGFloat? = nil
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(text.isEmpty || FinanceMoney.cents(text) != nil ? Theme.border : Theme.danger.opacity(0.6)))
            .focused($focused)
            .onAppear { text = cents.map(FinanceMoney.plain) ?? "" }
            .onChange(of: text) { _, value in
                let parsed = FinanceMoney.cents(value)
                if parsed != nil || value.isEmpty { cents = parsed }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, let cents { text = FinanceMoney.plain(cents) }
            }
    }
}

extension FinanceDay {
    /// For a `DatePicker`.
    static func binding(_ day: Binding<FinanceDay>) -> Binding<Date> {
        Binding(get: { day.wrappedValue.date }, set: { day.wrappedValue = FinanceDay($0) })
    }
}

/// A short line about an empty or missing thing, in the studios' quiet ink.
struct FinanceHint: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
