import Runestone
import UIKit

/// Explorer's gold masks sit over the glyphs, independent of text selection.
/// Only visible fragments are drawn; even an unwrapped, huge line stays cheap.
final class SearchableTextView: TextView {
    var searchMatches: [NSRange] = [] {
        didSet { refreshSearchHighlights() }
    }

    var currentMatch: Int? {
        didSet { refreshSearchHighlights() }
    }

    private let matchesLayer = CAShapeLayer()
    private let currentLayer = CAShapeLayer()
    private var pendingHighlightUpdate: DispatchWorkItem?
    private var previousViewportSize = CGSize.zero
    private var previousViewportInsets = UIEdgeInsets.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Wrapping removes horizontal scrolling, including an offset left by
        // navigating to a match in an unwrapped line.
        if isLineWrappingEnabled, contentOffset.x != 0 { contentOffset.x = 0 }
        if bounds.size != previousViewportSize || adjustedContentInset != previousViewportInsets {
            previousViewportSize = bounds.size
            previousViewportInsets = adjustedContentInset
            // The stack can resize without laying out its controller's root
            // view. Handle keyboard/rotation changes where the size changes.
            revealCurrentMatch(animated: false)
        }
        guard !searchMatches.isEmpty, pendingHighlightUpdate == nil else { return }
        // Like explorer, coalesce scrolling/layout updates to 10 draws per second.
        let update = DispatchWorkItem { [weak self] in
            self?.pendingHighlightUpdate = nil
            self?.refreshSearchHighlights()
        }
        pendingHighlightUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: update)
    }

    func revealCurrentMatch(animated: Bool = true) {
        guard let currentMatch, searchMatches.indices.contains(currentMatch) else { return }
        let range = searchMatches[currentMatch]
        let previousOffset = contentOffset
        // Lay out the target without selecting text or taking keyboard focus.
        scrollRangeToVisible(range)
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        let rect = firstRect(for: textRange)
        let inset = adjustedContentInset
        let height = bounds.height - inset.top - inset.bottom
        var target = contentOffset
        let bottom = max(-inset.top, contentSize.height - bounds.height + inset.bottom)
        target.y = min(bottom, max(-inset.top, rect.midY - inset.top - height / 2))
        setContentOffset(previousOffset, animated: false)
        setContentOffset(target, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        refreshSearchHighlights()
    }

    func refreshSearchHighlights() {
        pendingHighlightUpdate?.cancel()
        pendingHighlightUpdate = nil
        if matchesLayer.superlayer == nil {
            let gold = UIColor(red: 241 / 255, green: 196 / 255, blue: 15 / 255, alpha: 1)
            matchesLayer.fillColor = gold.withAlphaComponent(0.33).cgColor
            currentLayer.fillColor = gold.withAlphaComponent(0.66).cgColor
            layer.addSublayer(matchesLayer)
            layer.addSublayer(currentLayer)
        }
        let matchesPath = UIBezierPath()
        let currentPath = UIBezierPath()
        let viewport = bounds.inset(by: adjustedContentInset)
        if !searchMatches.isEmpty, viewport.width > 0, viewport.height > 0 {
            let lineHeight = max(1, theme.font.lineHeight * lineHeightMultiplier)
            var drawn = Set<NSRange>()
            // Ask only for the characters crossing each visible line fragment.
            // A single bounding range would include offscreen text in long lines.
            for y in stride(from: viewport.minY, through: viewport.maxY, by: lineHeight / 2) {
                guard let start = closestPosition(to: CGPoint(x: viewport.minX, y: y)),
                      let end = closestPosition(to: CGPoint(x: viewport.maxX, y: y)) else { continue }
                let lower = offset(from: beginningOfDocument, to: start)
                let upper = offset(from: beginningOfDocument, to: end)
                var index = ReportTextSearch.firstMatch(in: searchMatches, after: max(0, lower - 1))
                while index < searchMatches.count, searchMatches[index].location <= upper {
                    let match = searchMatches[index]
                    // Clip before asking Runestone for geometry, so a multiline
                    // match cannot cause layout of the rest of the document.
                    let range = NSIntersectionRange(match, NSRange(location: lower, length: max(0, upper - lower)))
                    if range.length > 0, drawn.insert(range).inserted,
                       let from = position(from: beginningOfDocument, offset: range.location),
                       let to = position(from: from, offset: range.length),
                       let textRange = textRange(from: from, to: to)
                    {
                        for selection in selectionRects(for: textRange) {
                            let rect = selection.rect.intersection(viewport)
                            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height * 0.2)
                            (index == currentMatch ? currentPath : matchesPath).append(path)
                        }
                    }
                    index += 1
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        matchesLayer.path = matchesPath.cgPath
        currentLayer.path = currentPath.cgPath
        CATransaction.commit()
    }
}
