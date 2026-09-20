import RunestoneEditor
import RunestoneThemeSupport
import UIKit

/// One of Runestone's themes with this app's own font in front of it.
///
/// The themes ship a fixed point size — 14 — and a viewer that ignores Dynamic
/// Type is a viewer half the people who need this app cannot read. Everything
/// that is not the font is the base theme's, forwarded, because the palette is
/// the part worth keeping. Ported from Fila.
final class ScaledEditorTheme: EditorTheme {
    static let baseSize: CGFloat = 13

    /// Light and dark. Re-derive this whenever the trait collection changes: a
    /// theme chosen once at load leaves the viewer in the wrong palette the
    /// moment the system flips.
    static func theme(for traits: UITraitCollection, scale: CGFloat = 1) -> ScaledEditorTheme {
        ScaledEditorTheme(
            base: traits.userInterfaceStyle == .dark ? OneDarkTheme() : TomorrowTheme(),
            pointSize: UIFontMetrics(forTextStyle: .body)
                .scaledValue(for: baseSize * scale, compatibleWith: traits)
        )
    }

    let font: UIFont
    let lineNumberFont: UIFont

    private let base: EditorTheme

    private init(base: EditorTheme, pointSize: CGFloat) {
        self.base = base
        font = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: max(9, pointSize - 2), weight: .regular)
    }

    var backgroundColor: UIColor {
        base.backgroundColor
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        base.userInterfaceStyle
    }

    var textColor: UIColor {
        base.textColor
    }

    var gutterBackgroundColor: UIColor {
        base.gutterBackgroundColor
    }

    var gutterHairlineColor: UIColor {
        base.gutterHairlineColor
    }

    var gutterHairlineWidth: CGFloat {
        base.gutterHairlineWidth
    }

    var lineNumberColor: UIColor {
        base.lineNumberColor
    }

    var selectedLineBackgroundColor: UIColor {
        base.selectedLineBackgroundColor
    }

    var selectedLinesLineNumberColor: UIColor {
        base.selectedLinesLineNumberColor
    }

    var selectedLinesGutterBackgroundColor: UIColor {
        base.selectedLinesGutterBackgroundColor
    }

    var invisibleCharactersColor: UIColor {
        base.invisibleCharactersColor
    }

    var pageGuideHairlineColor: UIColor {
        base.pageGuideHairlineColor
    }

    var pageGuideHairlineWidth: CGFloat {
        base.pageGuideHairlineWidth
    }

    var pageGuideBackgroundColor: UIColor {
        base.pageGuideBackgroundColor
    }

    var markedTextBackgroundColor: UIColor {
        base.markedTextBackgroundColor
    }

    var markedTextBackgroundCornerRadius: CGFloat {
        base.markedTextBackgroundCornerRadius
    }

    func textColor(for highlightName: String) -> UIColor? {
        base.textColor(for: highlightName)
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        base.fontTraits(for: highlightName)
    }
}
