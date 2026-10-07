// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import Foundation

/// Line break mode for text view.
public enum LineBreakMode: Int, CaseIterable {
    /// Wrap at word boundaries.
    case byWordWrapping = 0
    /// Wrap at character boundaries.
    case byCharWrapping = 1
}
