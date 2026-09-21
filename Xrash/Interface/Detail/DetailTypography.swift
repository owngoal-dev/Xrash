import UIKit

/// The type on a report screen, which is two families and no more.
///
/// What the app says is body: a field's name in bold, a row that opens
/// something in regular. What the *report* says is one small monospace —
/// every value under a field name, Application Information, the stacks, a
/// panic — and colour is what tells a symbol from an address. A 12-point
/// symbol over an 11-point address, beside a title3 header and a proportional
/// incident id, made one screen read as four.
enum DetailTypography {
    /// Bold body: the first line of a field row.
    static var name: UIFont {
        .preferredFont(forTextStyle: .body).withWeight(.bold)
    }

    /// Body: a value, whether it sits under a name or stands on its own.
    static var value: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    /// Monospaced footnote: one size for every line a machine wrote.
    static func mono(_ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 12, weight: weight)
        )
    }
}
