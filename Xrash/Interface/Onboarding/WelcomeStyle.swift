import UIKit

/// The welcome pages' typography and colours, ported with the pages themselves
/// from Irisin (`Irisin/Interface/DesignTokens/WelcomeStyle.swift`, MIT, the
/// same owner), which took them from FlowDown. Every number here is the
/// original's; the accent is this app's red, and `counterFont` is Irisin's
/// `UIFont.monospacedDigit(.footnote)` spelled out, since Xrash has no type
/// ramp of its own to take it from.
enum WelcomeStyle {
    /// The fixed, bold, two-line heading of the welcome pages. Fixed on
    /// purpose, as in the original: a display size that grew with Dynamic Type
    /// would take the page over.
    static var titleFont: UIFont {
        .systemFont(ofSize: 32, weight: .bold)
    }

    /// The system body style used for the introduction under a heading.
    static var subtitleFont: UIFont {
        .preferredFont(forTextStyle: .body)
    }

    /// The system subheadline with the bold trait of the original's rows.
    static var featureTitleFont: UIFont {
        .preferredFont(forTextStyle: .subheadline).withWeight(.bold)
    }

    /// The system footnote style used under each row's title.
    static var detailFont: UIFont {
        .preferredFont(forTextStyle: .footnote)
    }

    /// A count that rises while it is read: digits of one width, so "9 of 10"
    /// becoming "10 of 10" does not shift the line. Irisin's
    /// `monospacedDigit(.footnote)` — footnote metrics over 13 points.
    static var counterFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
    }

    /// The system headline assigned before the filled button configuration.
    static var buttonFont: UIFont {
        .preferredFont(forTextStyle: .headline)
    }

    /// The original's fixed-size, medium-weight row symbols.
    static var featureSymbol: UIImage.SymbolConfiguration {
        .init(pointSize: 16, weight: .medium)
    }

    /// The system sheet ground of the original welcome page. Both pages use it:
    /// the original's later pages sit on the grouped ground because they are
    /// lists, and neither of ours is — one ground, and the bar above the button
    /// does not change shade when a page is pushed.
    static var background: UIColor {
        .systemBackground
    }

    static var titleColor: UIColor {
        .label
    }

    static var detailColor: UIColor {
        .secondaryLabel
    }

    /// The app icon's shadow, as in the original.
    static var iconShadow: UIColor {
        .black
    }

    /// The app's own red, spelled as the app delegate spells it for the alerts.
    /// Stands in for the original's `.buttonNormal`.
    static var accent: UIColor {
        UIColor(named: "AccentColor") ?? .systemRed
    }

    /// The horizontal margin of everything on both pages — the original's
    /// content inset, and the same number its action bar insets its button by.
    static let horizontalMargin: CGFloat = 24

    /// Where a page that opens on its heading starts it: where the first
    /// page's icon starts, its 28 of inset and the 64 above the icon.
    static let headingTopMargin: CGFloat = 92
}
