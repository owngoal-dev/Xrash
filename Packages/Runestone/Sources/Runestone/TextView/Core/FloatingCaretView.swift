// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import UIKit

final class FloatingCaretView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = floor(bounds.width / 2)
    }
}
