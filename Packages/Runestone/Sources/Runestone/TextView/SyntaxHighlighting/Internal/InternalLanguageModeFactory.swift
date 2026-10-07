// SPDX-License-Identifier: MIT
// Upstream attribution and license: see Packages/Runestone/README.md and LICENSE files.
import Foundation

enum InternalLanguageModeFactory {
    static func internalLanguageMode(from languageMode: LanguageMode, stringView: StringView, lineManager: LineManager) -> InternalLanguageMode {
        switch languageMode {
        case is PlainTextLanguageMode:
            PlainTextInternalLanguageMode()
        case let languageMode as TreeSitterLanguageMode:
            TreeSitterInternalLanguageMode(
                language: languageMode.language.internalLanguage,
                languageProvider: languageMode.languageProvider,
                stringView: stringView,
                lineManager: lineManager
            )
        default:
            fatalError("\(languageMode) is not a supported language mode")
        }
    }
}
