import UIKit

/// The type on a report screen, which is two families and no more.
///
/// What the app says is proportional: a field's name in semibold at its
/// value's size, a row that opens something in regular body. What the
/// *report* says is one small monospace —
/// every value under a field name, Application Information, the stacks, a
/// panic — and colour is what tells a symbol from an address. A 12-point
/// symbol over an 11-point address, beside a title3 header and a proportional
/// incident id, made one screen read as four.
enum DetailTypography {
    /// The first line of a field row: the size of the value under it, in the
    /// proportional face and semibold. Bold body over a 12-point value read
    /// as a headline and a caption; this reads as a label and its value.
    static var name: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: monoSize, weight: .semibold)
        )
    }

    /// Body: a value, whether it sits under a name or stands on its own.
    static var value: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    /// Monospaced footnote: one size for every line a machine wrote.
    static func mono(_ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: monoSize, weight: weight)
        )
    }

    private static let monoSize: CGFloat = 12
}
