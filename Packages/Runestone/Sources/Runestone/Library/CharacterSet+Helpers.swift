// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import Foundation

extension CharacterSet {
    func containsAllCharacters(of string: String) -> Bool {
        var containsAllCharacters = true
        for char in string.unicodeScalars where !contains(char) {
            containsAllCharacters = false
            break
        }
        return containsAllCharacters
    }
}
