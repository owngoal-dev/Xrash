import Foundation

/// UTF-16 ranges, shared by background matching and the visible highlight layer.
enum ReportTextSearch {
    static func matches(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty,
              let expression = try? NSRegularExpression(
                  pattern: NSRegularExpression.escapedPattern(for: query), options: .caseInsensitive
              ) else { return [] }
        var ranges: [NSRange] = []
        expression.enumerateMatches(
            in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)
        ) { match, _, stop in
            if Task.isCancelled {
                stop.pointee = true
            } else if let match, match.range.length > 0 {
                ranges.append(match.range)
            }
        }
        return ranges
    }

    /// First match touching or following an offset, without walking the report.
    static func firstMatch(in ranges: [NSRange], after offset: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(ranges[middle]) <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
