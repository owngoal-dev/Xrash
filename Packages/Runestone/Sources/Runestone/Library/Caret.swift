// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import UIKit

enum Caret {
    static let width: CGFloat = 2

    static func defaultHeight(for font: UIFont?) -> CGFloat {
        font?.lineHeight ?? 15
    }
}
