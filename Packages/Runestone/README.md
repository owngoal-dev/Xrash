# Runestone

Vendored from Irisin's source package, keeping the editor and JSON highlighting
used by Xrash. This replaces `Lakr233/Runestone.xcframework` 0.3.2, whose combined
static library linked every language into the app. Plain text needs no grammar.

| Directory | Origin | License |
| --- | --- | --- |
| `Sources/Runestone` | [simonbs/Runestone](https://github.com/simonbs/Runestone) 0.5.2 (`592434a1`), without its DocC catalog | MIT (`LICENSE`), Simon Støvring |
| `Sources/TreeSitter` | [tree-sitter/tree-sitter](https://github.com/tree-sitter/tree-sitter), as `Lakr233/Runestone.xcframework` 0.3.2 vendors it | MIT (`Sources/TreeSitter/LICENSE`) |
| `Sources/TreeSitterJSON` | [simonbs/TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages), as the same xcframework vendors it | MIT (`Sources/TreeSitterJSON/LICENSE`) |
| `Sources/RunestoneLanguageSupport` | JSON helper and highlight query from the same language package | MIT (`LICENSE`) |
| `Sources/RunestoneThemeSupport` | Tomorrow and One Dark from Runestone's example themes, with colors written in code | MIT (`LICENSE`) |

## Changes from upstream

- Retain only the JSON grammar and the two themes used by the app. Queries are
  string literals; theme colors need no separate asset catalog.
- Preserve iOS 15 and Mac Catalyst support. `EditMenuController` restores the
  upstream 0.5.2 `UIMenuController` fallback removed by Irisin, and dismisses
  through the appropriate menu API on each OS.
- Irisin's C importer compatibility changes are retained: `TreeSitter.h`
  completes the opaque handle structs, and Swift holds typed pointers.
- Use Swift 5 language mode and concise `#file` names for the upstream sources.
  Preserve upstream notices and mark vendored source files with the MIT license.

The app uses `TextView` directly, without the xcframework's all-language
registration wrapper. Adding a grammar requires its source and license here.
