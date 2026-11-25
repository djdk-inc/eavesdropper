import EavesdropperCore
import Foundation
import FoundationModels

enum SummaryError: Error, CustomStringConvertible {
    case unavailable(String)
    case emptyTranscript

    var description: String {
        switch self {
        case let .unavailable(reason): "The on-device model isn't available: \(reason)."
        case .emptyTranscript: "There's no transcript to summarize."
        }
    }
}

private let notesInstructions = """
You write meeting notes from an automatic transcript. The transcript has misheard words; infer the meaning \
but never invent facts.

Each line starts with who spoke: "You" is the person who recorded the meeting; "Speaker 1", "Speaker 2" (or \
"Others") are other people. When someone says "I'll do X", the owner of X is that line's speaker label, or a \
name if one is said: "Speaker 1: I'll write the notes" means the owner is Speaker 1. "I" always means the \
speaker of that line, never "You". Only a line labeled "You" can give "You" a task.

Write Markdown in this order:
## Summary
Always two or three full sentences on what was discussed and where it landed.
## Decisions
## Action items
One bullet per task: owner, task, and when if said.
## Open questions
Leave out a section entirely (heading included) when it would be empty; never write "None". Be brief.
"""

private let partInstructions = """
You condense one part of a meeting transcript. The transcript has misheard words; infer the meaning but \
never invent facts. Each line starts with who spoke. Write short bullets: points discussed, decisions, tasks, \
and open questions. Start each bullet with the speaker label (or name) it came from, e.g. "Speaker 2: will tell support".
"""

/// Transcript characters per request: the model reads about 4,096 tokens in total, so a part of
/// ~6,000 characters (~1,500 tokens) leaves room for the instructions and the answer.
private let partCharacters = 6_000

private func ask(_ instructions: String, _ prompt: String) async throws -> String {
    let session = LanguageModelSession(instructions: instructions)
    return try await session.respond(to: prompt).content
}

/// Notes for a meeting from macOS's on-device language model; nothing leaves the Mac.
/// Long meetings are condensed part by part, then the parts' notes are combined.
func summarize(_ meeting: Meeting) async throws -> Summary {
    switch SystemLanguageModel.default.availability {
    case .available: break
    case let .unavailable(reason): throw SummaryError.unavailable("\(reason)")
    }
    let chunks = transcriptChunks(meeting.transcript, maxCharacters: partCharacters)
    guard !chunks.isEmpty else { throw SummaryError.emptyTranscript }

    var material = chunks
    // Condense until everything fits one request (each round shrinks the text several-fold).
    while material.count > 1 {
        // One at a time: macOS runs one on-device model request at a time, so parallel parts measured no faster.
        var condensed = [String]()
        for (i, part) in material.enumerated() {
            log("summary: condensing part \(i + 1) of \(material.count)")
            condensed.append(try await ask(partInstructions, part))
        }
        let next = combinedParts(condensed)
        guard next.count < material.count else {
            // Not shrinking (very long parts): keep what fits rather than loop.
            material = [String(next.joined(separator: "\n\n").prefix(partCharacters))]
            break
        }
        material = next
    }
    let labels = speakerLabels(meeting.transcript)
    let recorder = labels.contains("You") ? "" : "\nThe recorder (\"You\") did not speak, so has no tasks."
    let notes = try await ask(notesInstructions, "Meeting: \(meeting.title)\nPeople speaking: \(labels.joined(separator: ", "))\(recorder)\n\n\(material[0])")
    return Summary(text: cleanNotes(notes), createdAt: Date())
}

/// Groups condensed parts back into requests of at most `partCharacters`.
private func combinedParts(_ parts: [String]) -> [String] {
    var groups = [String]()
    var current = ""
    for part in parts {
        if !current.isEmpty, current.count + part.count + 2 > partCharacters {
            groups.append(current)
            current = ""
        }
        current += (current.isEmpty ? "" : "\n\n") + part
    }
    if !current.isEmpty { groups.append(current) }
    return groups
}
