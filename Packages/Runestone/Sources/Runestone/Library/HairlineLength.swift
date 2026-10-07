// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import UIKit

#if compiler(<5.9) || !os(visionOS)
    let hairlineLength = 1 / UIScreen.main.scale
#else
    let hairlineLength: CGFloat = 1
#endif
