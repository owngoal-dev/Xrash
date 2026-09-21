import UIKit

/// The type on a report screen, which is two families and no more.
///
/// The card at the top is prose: body, and a field's name is bold where its
/// value is `secondaryLabel`. Everything below it — Application Information,
/// the stacks, a panic — is a machine's own words, so it is one monospaced
/// footnote throughout and colour is what tells a symbol from an address. A
/// monospaced exception line, an 11-point address and a 12-point symbol made
/// one screen read as three.
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
