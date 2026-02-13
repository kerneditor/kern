import Foundation

/// GitHub-style heading slugger used for in-document anchor navigation.
///
/// This is intentionally conservative and ASCII-friendly. We can evolve it toward full
/// GitHub parity (unicode + punctuation edge cases) as we add more fixtures/cases.
enum GFMHeadingSlugger {
    static func slug(_ s: String) -> String {
        let lower = s.lowercased()

        var out = ""
        out.reserveCapacity(lower.count)

        var lastWasHyphen = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
                continue
            }

            // Treat whitespace and hyphen-like separators as '-'.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" {
                if !lastWasHyphen, !out.isEmpty {
                    out.append("-")
                    lastWasHyphen = true
                }
                continue
            }

            // Drop punctuation/other symbols.
        }

        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

/// Builds an index from `#heading-slug` to the character location of the corresponding heading
/// paragraph in the editor's attributed string.
struct HeadingAnchorIndex {
    static func make(from attributed: NSAttributedString) -> [String: Int] {
        let ns = attributed.string as NSString
        var idx = 0

        var counts: [String: Int] = [:]
        var out: [String: Int] = [:]

        while idx < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            if paraRange.length == 0 { break }

            let kindRaw = attributed.attribute(.kernBlockKind, at: paraRange.location, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph

            if kind == .heading {
                let contentRange = paragraphContentRange(ns: ns, paraRange: paraRange)
                let body = stripMarkerPrefix(attributed: attributed, range: contentRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !body.isEmpty {
                    let base = GFMHeadingSlugger.slug(body)
                    if !base.isEmpty {
                        let n = counts[base] ?? 0
                        let slug = (n == 0) ? base : "\(base)-\(n)"
                        counts[base] = n + 1
                        if out[slug] == nil {
                            out[slug] = paraRange.location
                        }
                    }
                }
            }

            idx = paraRange.location + paraRange.length
        }

        return out
    }

    private static func paragraphContentRange(ns: NSString, paraRange: NSRange) -> NSRange {
        var len = paraRange.length
        if len > 0 {
            let last = paraRange.location + len - 1
            if last < ns.length, ns.character(at: last) == 10 { // '\n'
                len -= 1
            }
        }
        return NSRange(location: paraRange.location, length: max(0, len))
    }

    private static func stripMarkerPrefix(attributed: NSAttributedString, range: NSRange) -> String {
        if range.length == 0 { return "" }

        var start = range.location
        let end = range.location + range.length
        while start < end {
            let isMarker = (attributed.attribute(.kernMarker, at: start, effectiveRange: nil) as? Bool) ?? false
            if !isMarker { break }
            start += 1
        }

        let bodyRange = NSRange(location: start, length: max(0, end - start))
        if bodyRange.length == 0 { return "" }
        return attributed.attributedSubstring(from: bodyRange).string
    }
}

