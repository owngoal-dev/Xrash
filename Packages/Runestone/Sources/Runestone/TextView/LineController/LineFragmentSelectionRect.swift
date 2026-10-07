// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import CoreGraphics
import Foundation

struct LineFragmentSelectionRect {
    let rect: CGRect
    let range: NSRange
    let extendsBeyondEnd: Bool
}
