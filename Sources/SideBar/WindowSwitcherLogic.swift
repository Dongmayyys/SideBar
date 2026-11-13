import Foundation
import CoreFoundation
import CoreGraphics

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
    var bundleID: String? = nil

    func isEligible(ownPID: Int32, focusedID: UInt32?, stashedIDs: Set<UInt32>) -> Bool {
        isRegularApplication && isStandardWindow && hasValidSize && (hasSpace || isMinimized)
            && pid != ownPID && id != focusedID && !stashedIDs.contains(id)
    }
}

struct WindowSwitcherSearchField {
    private let text: WindowSwitcherMappedText
    private let latin: WindowSwitcherMappedText
    private let wordStarts: [WindowSwitcherMappedText]
    private let initials: WindowSwitcherMappedText

    init(_ value: String) {
        let transformed = NSMutableString(string: value)
        CFStringTransform(transformed, nil, kCFStringTransformToLatin, false)
        CFStringTransform(transformed, nil, kCFStringTransformStripCombiningMarks, false)
        // Split camel-case names before lowercasing, as well as ordinary words and pinyin syllables.
        let spaced = (transformed as String).replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = Self.normalize(spaced).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        text = WindowSwitcherMappedText(source: value, transformed: Self.normalize(value), transliterate: false)
        latin = WindowSwitcherMappedText(source: value, transformed: words.joined(), transliterate: true)
        var offset = 0
        var mappedWords: [WindowSwitcherMappedText] = []
        for word in words {
            let end = offset + word.count
            mappedWords.append(WindowSwitcherMappedText(value: word, sources: Array(latin.sources[offset..<end])))
            offset = end
        }
        wordStarts = mappedWords.indices.dropFirst().flatMap {
            [WindowSwitcherMappedText.joined(Array(mappedWords[$0...])),
             WindowSwitcherMappedText.joined(Array(mappedWords[$0...]), spaced: true)]
        }
        initials = WindowSwitcherMappedText(
            value: words.compactMap(\.first).map(String.init).joined(),
            sources: mappedWords.compactMap { $0.sources.first })
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func match(_ query: String) -> WindowSwitcherTextMatch? {
        guard !query.isEmpty else { return WindowSwitcherTextMatch(grade: .exact, ranges: []) }
        for variant in [text, latin] where variant.value == query {
            return WindowSwitcherTextMatch(grade: .exact, ranges: variant.highlight(Array(variant.sources.indices)))
        }
        for variant in [text, latin] where variant.value.hasPrefix(query) {
            return WindowSwitcherTextMatch(grade: .prefix, ranges: variant.highlight(Array(0..<query.count)))
        }
        for variant in wordStarts where variant.value.hasPrefix(query) {
            return WindowSwitcherTextMatch(grade: .wordStart, ranges: variant.highlight(Array(0..<query.count)))
        }
        if let range = initials.value.range(of: query) {
            let start = initials.value.distance(from: initials.value.startIndex, to: range.lowerBound)
            return WindowSwitcherTextMatch(grade: .initials, ranges: initials.highlight(Array(start..<(start + query.count))))
        }
        for variant in [text, latin] {
            // Contiguous occurrences are also subsequences; prefer their compact source span
            // over a greedy earlier character elsewhere in the title.
            if let range = variant.value.range(of: query) {
                let start = variant.value.distance(from: variant.value.startIndex, to: range.lowerBound)
                return WindowSwitcherTextMatch(grade: .subsequence, ranges: variant.highlight(Array(start..<(start + query.count))))
            }
            var positions: [Int] = []
            let wanted = Array(query)
            for (index, character) in variant.value.enumerated() where character == wanted[positions.count] {
                positions.append(index)
                if positions.count == wanted.count {
                    return WindowSwitcherTextMatch(grade: .subsequence, ranges: variant.highlight(positions))
                }
            }
        }
        return nil
    }
}

struct WindowSwitcherTextMatch {
    let grade: WindowSwitcherMatch
    /// UTF-16 source ranges, directly usable by NSAttributedString, including composed characters.
    let ranges: [NSRange]
}

private struct WindowSwitcherMappedText {
    let value: String
    let sources: [NSRange]

    init(value: String, sources: [NSRange]) {
        self.value = value
        self.sources = sources
    }

    init(source: String, transformed: String, transliterate: Bool) {
        var expected: [Character] = []
        var ranges: [NSRange] = []
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: .byComposedCharacterSequences) { part, range, _, _ in
            guard let part else { return }
            let fragment = NSMutableString(string: part)
            if transliterate && !part.unicodeScalars.allSatisfy(\.isASCII) {
                CFStringTransform(fragment, nil, kCFStringTransformToLatin, false)
                CFStringTransform(fragment, nil, kCFStringTransformStripCombiningMarks, false)
            }
            let folded = (fragment as String).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let characters = folded.filter { !transliterate || $0.isLetter || $0.isNumber }
            expected.append(contentsOf: characters)
            ranges.append(contentsOf: characters.map { _ in NSRange(range, in: source) })
        }
        value = transformed
        let actual = Array(transformed)
        if expected == actual { sources = ranges; return }
        // Keep whole-string transliteration (e.g. 重庆 -> chongqing), but map its contextual
        // pronunciation edits back to the original graphemes rather than transliterating per Hanzi.
        let edits = actual.difference(from: expected)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for edit in edits {
            switch edit {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var mapped = [NSRange](repeating: NSRange(location: 0, length: 0), count: actual.count)
        var old = 0
        var new = 0
        while old < expected.count || new < actual.count {
            let oldStart = old
            let newStart = new
            while removed.contains(old) { old += 1 }
            while inserted.contains(new) { new += 1 }
            if old != oldStart || new != newStart {
                let replaced = ranges[oldStart..<old]
                let fallback = ranges.isEmpty ? NSRange(location: 0, length: 0) : ranges[min(old, ranges.count - 1)]
                let sourceRange = replaced.reduce(nil as NSRange?) { result, range in
                    result.map { NSUnionRange($0, range) } ?? range
                } ?? fallback
                for index in newStart..<new { mapped[index] = sourceRange }
            } else {
                mapped[new] = ranges[old]
                old += 1
                new += 1
            }
        }
        sources = mapped
    }

    static func joined(_ words: [Self], spaced: Bool = false) -> Self {
        var value = ""
        var sources: [NSRange] = []
        for word in words {
            if spaced && !value.isEmpty {
                value += " "
                let start = sources.last.map(NSMaxRange) ?? 0
                sources.append(NSRange(location: start, length: max(0, (word.sources.first?.location ?? start) - start)))
            }
            value += word.value
            sources += word.sources
        }
        return Self(value: value, sources: sources)
    }

    func highlight(_ positions: [Int]) -> [NSRange] {
        let sorted = positions.map { sources[$0] }.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

enum WindowSwitcherMatch: Int {
    case exact, prefix, wordStart, initials, subsequence
}

enum WindowSwitcherSearch {
    static func match(query: String, fields: [WindowSwitcherSearchField]) -> WindowSwitcherMatch? {
        let query = WindowSwitcherSearchField.normalize(query)
        guard !query.isEmpty else { return .exact }
        return fields.compactMap { $0.match(query)?.grade }.min { $0.rawValue < $1.rawValue }
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

struct WindowSwitcherRow {
    enum ApplicationID: Hashable { case bundle(String), process(Int32) }
    enum ID: Hashable { case application(ApplicationID), window(UInt32) }
    enum Kind { case application, window, singleWindow }
    let id: ID
    let kind: Kind
    let targetID: UInt32
    let pid: Int32
    let appName: String
    let title: String
    let appHighlights: [NSRange]
    let titleHighlights: [NSRange]
}

enum WindowSwitcherList {
    static func rows(query: String, candidates: [WindowSwitcherCandidate], fields: [UInt32: [WindowSwitcherSearchField]],
                     recency: WindowSwitcherRecency, ownPID: Int32, focusedID: UInt32?, stashedIDs: Set<UInt32>) -> [WindowSwitcherRow] {
        let eligible = candidates.filter { $0.isEligible(ownPID: ownPID, focusedID: focusedID, stashedIDs: stashedIDs) }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        func appID(_ candidate: WindowSwitcherCandidate) -> WindowSwitcherRow.ApplicationID {
            candidate.bundleID.map { .bundle($0) } ?? .process(candidate.pid)
        }
        let applications = Dictionary(grouping: eligible, by: appID)
        let sorted = WindowSwitcherSearch.sortedIDs(query: query, candidates: eligible, fields: fields, recency: recency,
                                                    ownPID: ownPID, focusedID: focusedID, stashedIDs: stashedIDs)
        let matched = sorted.compactMap { byID[$0] }
        let matchedGroups = Dictionary(grouping: matched, by: appID)
        let normalizedQuery = WindowSwitcherSearchField.normalize(query)
        func row(_ candidate: WindowSwitcherCandidate, kind: WindowSwitcherRow.Kind) -> WindowSwitcherRow {
            let search = fields[candidate.id] ?? [WindowSwitcherSearchField(candidate.appName), WindowSwitcherSearchField(candidate.title)]
            return WindowSwitcherRow(
                id: kind == .application ? .application(appID(candidate)) : .window(candidate.id), kind: kind,
                targetID: candidate.id, pid: candidate.pid, appName: candidate.appName, title: candidate.title,
                appHighlights: search.first?.match(normalizedQuery)?.ranges ?? [],
                titleHighlights: search.dropFirst().first?.match(normalizedQuery)?.ranges ?? [])
        }
        var result: [WindowSwitcherRow] = []
        var seen: Set<WindowSwitcherRow.ApplicationID> = []
        for candidate in matched {
            let application = appID(candidate)
            guard seen.insert(application).inserted, let members = applications[application],
                  let displayed = matchedGroups[application] else { continue }
            if members.count == 1 {
                result.append(row(candidate, kind: .singleWindow))
                continue
            }
            let recent = WindowSwitcherSearch.sortedIDs(query: "", candidates: members, fields: fields, recency: recency,
                                                        ownPID: ownPID, focusedID: focusedID, stashedIDs: stashedIDs)
            if let target = recent.first.flatMap({ byID[$0] }) { result.append(row(target, kind: .application)) }
            result += displayed.map { row($0, kind: .window) }
        }
        return result
    }
}

struct WindowSwitcherSelection {
    private(set) var selectedID: WindowSwitcherRow.ID?
    private var keyboardID: WindowSwitcherRow.ID?

    mutating func reconcile(_ ids: [WindowSwitcherRow.ID], preservingSelection: Bool) {
        if !preservingSelection || !ids.contains(where: { $0 == keyboardID }) { keyboardID = ids.first }
        if !preservingSelection || !ids.contains(where: { $0 == selectedID }) { selectedID = keyboardID }
    }

    mutating func move(to id: WindowSwitcherRow.ID) {
        keyboardID = id
        selectedID = id
    }

    mutating func hover(_ id: WindowSwitcherRow.ID?) {
        selectedID = id ?? keyboardID
    }
}

enum WindowSwitcherPanelLayout {
    static let rowHeight: CGFloat = 30

    static func frame(visibleFrame: CGRect, rowCount: Int) -> CGRect {
        let width = min(640, max(0, visibleFrame.width - 32))
        let height = min(480, visibleFrame.height * 0.65, 64 + CGFloat(max(1, rowCount)) * rowHeight)
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.maxY - visibleFrame.height * 0.18 - height,
                      width: width, height: height)
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
