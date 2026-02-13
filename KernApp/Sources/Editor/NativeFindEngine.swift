import Foundation

/// Pure helpers for find/replace. Returns `NSRange` values using UTF-16 indexing
/// (matching `NSString` and TextKit expectations).
enum NativeFindEngine {
    struct Options {
        var caseSensitive: Bool = false
        var diacriticInsensitive: Bool = true
    }

    static func allMatches(in text: String, query: String, options: Options = .init()) -> [NSRange] {
        guard !query.isEmpty else { return [] }

        let hay = text as NSString
        let needle = query

        var compare: NSString.CompareOptions = []
        if !options.caseSensitive { compare.insert(.caseInsensitive) }
        if options.diacriticInsensitive { compare.insert(.diacriticInsensitive) }

        var matches: [NSRange] = []
        var searchRange = NSRange(location: 0, length: hay.length)

        while searchRange.location < hay.length, searchRange.length > 0 {
            let r = hay.range(of: needle, options: compare, range: searchRange)
            if r.location == NSNotFound { break }
            matches.append(r)

            let next = r.location + max(1, r.length)
            if next >= hay.length { break }
            searchRange = NSRange(location: next, length: hay.length - next)
        }

        return matches
    }

    static func replace(in storage: NSMutableAttributedString, range: NSRange, replacement: String) {
        guard range.location >= 0, range.length > 0, range.location + range.length <= storage.length else { return }

        // Preserve local styling by inheriting attributes from the start of the match.
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        let rep = NSAttributedString(string: replacement, attributes: attrs)
        storage.replaceCharacters(in: range, with: rep)
    }
}

