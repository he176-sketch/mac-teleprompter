import Foundation

struct FollowUpdate {
    /// Position in the unchanged original script, not in the recognition result.
    let utf16Offset: Int
    let matchedUTF16Range: NSRange
    let confidence: Double
    let kind: String
}

/// A conservative local matcher. It receives cumulative recognition hypotheses;
/// callers own capture, recognition, and UI animation. It never advances on a timer.
struct ScriptFollower {
    private struct Token {
        let character: Character
        let offset: Int
        let sentence: Int
    }

    private struct Sentence {
        let first: Int
        let end: Int
        let range: NSRange
    }

    private struct Cell {
        let edits: Int
        let matches: Int
        let start: Int
    }

    private struct Candidate {
        let first: Int
        let last: Int
        let confidence: Double
        let matches: Int
    }

    private var tokens: [Token] = []
    private var sentences: [Sentence] = []
    private var cursor = 0
    private var lastTaskID: String?
    private var lastTranscript: [Character] = []
    private var hasMatch = false
    private var ignoredInterjections: Set<Character> = []
    private(set) var currentUTF16Offset = 0

    init(script: String) {
        var originalOffset = 0
        var sentenceOffset = 0
        var sentenceFirst = 0
        let boundaries = CharacterSet(charactersIn: "。！？!?；;\n.")
        for character in script {
            let text = String(character)
            let length = text.utf16.count
            for normalized in Self.normalized(text) {
                tokens.append(Token(character: normalized, offset: originalOffset,
                                    sentence: sentences.count))
            }
            originalOffset += length
            if text.unicodeScalars.contains(where: { boundaries.contains($0) }) {
                // A paragraph commonly ends in "。\n". The newline must not
                // consume another sentence of the bounded search window.
                if tokens.count > sentenceFirst {
                    sentences.append(Sentence(first: sentenceFirst, end: tokens.count,
                                              range: NSRange(location: sentenceOffset,
                                                             length: originalOffset - sentenceOffset)))
                }
                sentenceFirst = tokens.count
                sentenceOffset = originalOffset
            }
        }
        if tokens.count > sentenceFirst || sentences.isEmpty {
            sentences.append(Sentence(first: sentenceFirst, end: tokens.count,
                                      range: NSRange(location: sentenceOffset,
                                                     length: originalOffset - sentenceOffset)))
        }
        // Only recognition-side search text is normalized. An interjection that
        // actually occurs in the original is retained so it can still be read.
        ignoredInterjections = Set("嗯呃啊").subtracting(Set(tokens.map(\.character)))
    }

    /// For preparation or exceptional recovery. A layout/font change must not call this.
    mutating func seek(utf16Offset: Int) {
        guard !tokens.isEmpty else { return }
        cursor = tokens.lastIndex(where: { $0.offset <= max(0, utf16Offset) }) ?? 0
        currentUTF16Offset = tokens[cursor].offset
        lastTaskID = nil
        lastTranscript = []
        hasMatch = false
    }

    mutating func update(transcript: String, taskID: String) -> FollowUpdate? {
        guard !tokens.isEmpty else { return nil }
        let heard = Self.normalized(transcript).filter { !ignoredInterjections.contains($0) }
        let sameTask = taskID == lastTaskID
        if sameTask && heard == lastTranscript { return nil }

        var common = 0
        if sameTask {
            while common < min(heard.count, lastTranscript.count),
                  heard[common] == lastTranscript[common] { common += 1 }
        }
        let appended = sameTask && common == lastTranscript.count
        let revision = sameTask && !appended
        lastTaskID = taskID
        lastTranscript = heard
        guard heard.count >= 4 else { return nil }
        // A recognizer may shorten a hypothesis while removing duplicated words.
        // Match that correction, but the revision filter below forbids retreat.

        let freshCount = sameTask ? heard.count - common : heard.count
        let queryLength = min(24, min(heard.count, freshCount >= 8 ? freshCount : max(8, freshCount + 4)))
        let query = Array(heard.suffix(queryLength))
        let sentenceID = tokens[cursor].sentence
        let first = max(sentences[max(0, sentenceID - 1)].first, cursor - 72)
        let end = min(tokens.count, min(cursor + 80,
                       sentences[min(sentences.count - 1, sentenceID + 2)].end))
        guard first < end else { return nil }

        var candidates = align(query: query, first: first, end: end).filter {
            if $0.last < cursor {
                // Partial-result revisions must not drag the reading position back.
                return !revision && cursor - $0.last >= 4 && $0.matches >= 6 && $0.confidence >= 0.85
            }
            return true
        }
        candidates.sort {
            if abs($0.confidence - $1.confidence) > 0.0001 { return $0.confidence > $1.confidence }
            return abs($0.last - cursor) < abs($1.last - cursor)
        }
        guard let best = candidates.first else { return nil }

        // Different occurrences with essentially equal support are ambiguous.
        // Endpoints a few characters apart belong to the same fuzzy alignment.
        let competing = candidates.dropFirst().first {
            abs($0.last - best.last) >= 4 && abs($0.first - best.first) >= 4 &&
                $0.confidence >= best.confidence - 0.035
        }
        if competing != nil && !(best.first <= cursor && best.last >= cursor) { return nil }
        if hasMatch && best.last == cursor { return nil }

        let kind = best.last < cursor ? "repeat" : (hasMatch ? "advance" : "acquire")
        cursor = best.last
        currentUTF16Offset = tokens[cursor].offset
        hasMatch = true
        return FollowUpdate(utf16Offset: currentUTF16Offset,
                            matchedUTF16Range: sentences[tokens[cursor].sentence].range,
                            confidence: best.confidence, kind: kind)
    }

    private func align(query: [Character], first: Int, end: Int) -> [Candidate] {
        let source = Array(tokens[first..<end].map(\.character))
        // Free source prefixes allow substring matching, while every query character
        // must be explained by a match or an edit (including filler words).
        var previous = (0...source.count).map { Cell(edits: 0, matches: 0, start: $0) }
        for (i, character) in query.enumerated() {
            var row = [Cell(edits: i + 1, matches: 0, start: 0)]
            for j in source.indices {
                let equal = character == source[j]
                let diagonal = Cell(edits: previous[j].edits + (equal ? 0 : 1),
                                    matches: previous[j].matches + (equal ? 1 : 0),
                                    start: previous[j].start)
                let inserted = Cell(edits: previous[j + 1].edits + 1,
                                    matches: previous[j + 1].matches, start: previous[j + 1].start)
                let omitted = Cell(edits: row[j].edits + 1,
                                   matches: row[j].matches, start: row[j].start)
                let cell = [diagonal, inserted, omitted].min {
                    if $0.edits != $1.edits { return $0.edits < $1.edits }
                    return $0.matches > $1.matches
                }!
                row.append(cell)
            }
            previous = row
        }
        return (1...source.count).compactMap { column in
            let cell = previous[column]
            let span = column - cell.start
            guard span > 0 else { return nil }
            let confidence = 1 - Double(cell.edits) / Double(max(query.count, span))
            // Chinese partial results often revise the newest character once.
            // Allow one edit while keeping a strong contiguous match so a
            // single ASR typo cannot freeze the follower.
            let minimumMatches = query.count <= 4 ? max(3, query.count - 1) : min(5, query.count)
            guard confidence >= 0.75, cell.matches >= minimumMatches else { return nil }
            return Candidate(first: first + cell.start, last: first + column - 1,
                             confidence: confidence, matches: cell.matches)
        }
    }

    private static func normalized(_ text: String) -> [Character] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "zh_CN"))
        return folded.filter { character in
            character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
    }
}
