// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import Foundation

struct TreeSitterInjectedLanguage {
    let id: UnsafeRawPointer
    let languageName: String
    let textRange: TreeSitterTextRange
}
