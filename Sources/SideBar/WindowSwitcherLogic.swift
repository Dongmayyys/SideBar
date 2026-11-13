import Foundation
import CoreFoundation

/// Value-only inventory: no AX handles, sessions or changes to window state.
struct WindowSwitcherCandidate {
    let id: UInt32
    let pid: Int32
    let appName: String
    let title: String
    var isRegularApplication = true
    var isStandardWindow = true
    var hasValidSize = true
    var hasSpace = true
    var isMinimized = false

    func isEligible(ownPID: Int32, focusedID: UInt32?, stashedIDs: Set<UInt32>) -> Bool {
        isRegularApplication && isStandardWindow && hasValidSize && (hasSpace || isMinimized)
            && pid != ownPID && id != focusedID && !stashedIDs.contains(id)
    }
}

struct WindowSwitcherSearchField {
    let text: String
    let latin: String
    let wordStarts: [String]
    let initials: String

    init(_ value: String) {
        text = Self.normalize(value)
        let transformed = NSMutableString(string: value)
        CFStringTransform(transformed, nil, kCFStringTransformToLatin, false)
        CFStringTransform(transformed, nil, kCFStringTransformStripCombiningMarks, false)
        // Split camel-case names before lowercasing, as well as ordinary words and pinyin syllables.
        let spaced = (transformed as String).replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = Self.normalize(spaced).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        latin = words.joined()
        wordStarts = words.indices.flatMap { [words[$0...].joined(), words[$0...].joined(separator: " ")] }
        initials = words.compactMap(\.first).map(String.init).joined()
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WindowSwitcherMatch: Int {
    case exact, prefix, wordStart, initials, subsequence
}

enum WindowSwitcherSearch {
    static func match(query: String, fields: [WindowSwitcherSearchField]) -> WindowSwitcherMatch? {
        let query = WindowSwitcherSearchField.normalize(query)
        guard !query.isEmpty else { return .exact }
        return fields.compactMap { field -> WindowSwitcherMatch? in
            if field.text == query || field.latin == query { return .exact }
            if field.text.hasPrefix(query) || field.latin.hasPrefix(query) { return .prefix }
            if field.wordStarts.dropFirst(2).contains(where: { $0.hasPrefix(query) }) { return .wordStart }
            if field.initials.contains(query) { return .initials }
            if isSubsequence(query, of: field.text) || isSubsequence(query, of: field.latin) { return .subsequence }
            return nil
        }.min { $0.rawValue < $1.rawValue }
    }

    static func isSubsequence(_ query: String, of text: String) -> Bool {
        var remaining = query.makeIterator()
        var wanted = remaining.next()
        for character in text where character == wanted {
            wanted = remaining.next()
            if wanted == nil { return true }
        }
        return wanted == nil
    }

    static func sortedIDs(query: String, candidates: [WindowSwitcherCandidate],
                          fields: [UInt32: [WindowSwitcherSearchField]], recency: WindowSwitcherRecency,
                          ownPID: Int32, focusedID: UInt32?, stashedIDs: Set<UInt32>) -> [UInt32] {
        candidates.enumerated().compactMap { index, candidate -> (UInt32, Int, UInt64, Int)? in
            guard candidate.isEligible(ownPID: ownPID, focusedID: focusedID, stashedIDs: stashedIDs),
                  let match = match(query: query, fields: fields[candidate.id] ?? []) else { return nil }
            return (candidate.id, match.rawValue, recency.order[candidate.id] ?? 0, index)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.3 < $1.3
        }.map { $0.0 }
    }
}

struct WindowSwitcherRecency {
    private(set) var order: [UInt32: UInt64] = [:]
    private var clock: UInt64 = 0

    mutating func seed(stackingOrder: [UInt32]) {
        guard order.isEmpty else { return }
        for id in stackingOrder.reversed() { recordFocus(id) }
    }

    mutating func recordFocus(_ id: UInt32) {
        clock += 1
        order[id] = clock
    }

    mutating func retain(_ ids: Set<UInt32>) {
        order = order.filter { ids.contains($0.key) }
    }
}
