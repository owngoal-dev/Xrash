import UIKit

/// The type on a report screen, which is two families and no more.
///
/// What the app says is regular body: a field's name, and a row that opens
/// something. What the *report* says is one small monospace —
/// every value under a field name, Application Information, the stacks, a
/// panic — and colour is what tells a symbol from an address. A 12-point
/// symbol over an 11-point address, beside a title3 header and a proportional
/// incident id, made one screen read as four.
enum DetailTypography {
    /// The first line of a field row: plain body. The face already tells a
    /// name from the monospaced value under it, and weight on top of that
    /// read as a headline over a caption.
    static var name: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    /// Body: a value, whether it sits under a name or stands on its own.
    static var value: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    /// Monospaced footnote: one size for every line a machine wrote.
    static func mono(_ weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: monoSize, weight: weight),
        )
    }

    private static let monoSize: CGFloat = 12
}
