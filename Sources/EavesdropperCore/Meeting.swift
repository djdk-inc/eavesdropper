import Foundation

public struct TranscriptLine: Codable, Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    /// "You" (your mic) or "Others" (the call's sound).
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// One recorded call, saved as `meeting.json` in its folder.
public struct Meeting: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, transcribing, done, failed }

    public var id: String
    public var app: CallApp
    public var startedAt: Date
    public var endedAt: Date?
    /// The Meet/Zoom URL the call was on, when known.
    public var meetingURL: String?
    /// The Google Calendar invite this call belongs to, when one matched.
    public var event: CalendarEvent?
    public var status: Status
    public var error: String?
    public var transcript: [TranscriptLine] = []

    public init(id: String, app: CallApp, startedAt: Date, meetingURL: String?) {
        self.id = id
        self.app = app
        self.startedAt = startedAt
        self.meetingURL = meetingURL
        self.status = .recording
    }

    /// The invite's title, or the start time when no invite matched.
    public var title: String {
        if let t = event?.title, !t.isEmpty { return t }
        return "\(app.rawValue) call – \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The transcript as plain text, one "[mm:ss] Speaker: text" line each ("[h:mm:ss]" past the hour).
public func transcriptText(_ transcript: [TranscriptLine]) -> String {
    transcript.map { line in
        let t = Int(line.start)
        let stamp = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
        return "[\(stamp)] \(line.speaker): \(line.text)"
    }.joined(separator: "\n")
}

/// Interleaves your lines and the others' lines by time.
public func mergeTranscripts(you: [TranscriptLine], others: [TranscriptLine]) -> [TranscriptLine] {
    (you + others).sorted { $0.start < $1.start }
}

/// Meetings on disk: `<root>/<id>/meeting.json` next to that call's audio.
public struct MeetingStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func save(_ meeting: Meeting) throws {
        let dir = folder(for: meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(meeting).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
    }

    /// All meetings, newest first.
    public func all() -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))).flatMap { try? Self.decoder.decode(Meeting.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }
}
