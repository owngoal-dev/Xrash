// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import Foundation

/// Strategy to use when the end while navigating highlighted ranges.
public enum HighlightedRangeLoopingMode {
    /// Loop when navigating through highlighted ranges in a text view.
    case enabled
    /// Do not loop when navigating through highlighted ranges in a text view.
    case disabled
}
