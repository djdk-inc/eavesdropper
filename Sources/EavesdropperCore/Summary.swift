import Foundation

/// Meeting notes written on request by macOS's on-device language model.
public struct Summary: Codable, Equatable, Sendable {
    /// Markdown.
    public var text: String
    public var createdAt: Date

    public init(text: String, createdAt: Date) {
        self.text = text
        self.createdAt = createdAt
    }
}

/// Splits a transcript into pieces of at most `maxCharacters` of `transcriptText`, breaking only
/// between lines, so each fits the on-device model's small context window. A single line longer
/// than the limit gets a piece of its own.
public func transcriptChunks(_ transcript: [TranscriptLine], maxCharacters: Int) -> [String] {
    var chunks = [String]()
    var current = [String]()
    var size = 0
    for line in transcriptText(transcript).split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
        if !current.isEmpty, size + line.count + 1 > maxCharacters {
            chunks.append(current.joined(separator: "\n"))
            current = []
            size = 0
        }
        current.append(line)
        size += line.count + 1
    }
    if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
    return chunks
}

/// The distinct speaker labels in order of first appearance, e.g. ["You", "Speaker 1", "Speaker 2"].
public func speakerLabels(_ transcript: [TranscriptLine]) -> [String] {
    var seen = [String]()
    for line in transcript where !seen.contains(line.speaker) { seen.append(line.speaker) }
    return seen
}

/// Tidies model-written notes: drops "## " sections whose body is empty or just "None"/"N/A".
public func cleanNotes(_ notes: String) -> String {
    var sections = [[String]]()
    for line in notes.components(separatedBy: "\n") {
        if line.hasPrefix("## ") || sections.isEmpty { sections.append([line]) } else { sections[sections.count - 1].append(line) }
    }
    let empties: Set<String> = ["", "none", "none.", "n/a", "- none", "- none.", "* none", "* none.", "no open questions.", "no open questions raised."]
    return sections.filter { section in
        guard let head = section.first, head.hasPrefix("## ") else { return true }
        let body = section.dropFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return !body.isEmpty && !body.allSatisfy { empties.contains($0) }
    }.map { $0.joined(separator: "\n") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A piece of model-written notes for display: a "## " heading or a line of text.
public enum NoteBlock: Equatable, Sendable {
    case heading(String)
    case line(String)
}

/// Splits notes into headings and lines ("- " bullets become "• "), dropping blank lines and the leading "Summary" heading
/// (the window already titles the section "Summary").
public func noteBlocks(_ notes: String) -> [NoteBlock] {
    var blocks = [NoteBlock]()
    for raw in notes.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if blocks.isEmpty, title.lowercased() == "summary" { continue }
            blocks.append(.heading(title))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            blocks.append(.line("• " + line.dropFirst(2)))
        } else {
            blocks.append(.line(line))
        }
    }
    return blocks
}
