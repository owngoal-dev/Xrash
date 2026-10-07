// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import UIKit

extension UIFont {
    var totalLineHeight: CGFloat {
        ascender + abs(descender) + leading
    }
}
