import Foundation

public struct TranscriptLine: Codable, Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    /// When the line's speech ends (nil in meetings saved before speaker labels).
    public var end: TimeInterval?
    /// "You" (your mic), "Speaker N" (a voice on the call), or "Others" (the call, unsplit).
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, end: TimeInterval? = nil, speaker: String, text: String) {
        self.start = start
        self.end = end
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
    /// Notes from the on-device model, made when asked.
    public var summary: Summary?

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
        let name = app == .manual ? app.rawValue : "\(app.rawValue) call"
        return "\(name) – \(startedAt.formatted(date: .abbreviated, time: .shortened))"
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

/// A stretch of the call audio where one voice is talking, from the diarizer.
public struct SpeakerTurn: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// The diarizer's id for the voice; only equality matters.
    public var voice: String

    public init(start: TimeInterval, end: TimeInterval, voice: String) {
        self.start = start
        self.end = end
        self.voice = voice
    }
}

/// Relabels the call's lines by voice: each line goes to the voice that talks most during it
/// (or the nearest turn, when none overlaps). Voices are numbered Speaker 1, 2, … in order of
/// first appearance. With no turns, lines keep their label.
public func labelSpeakers(_ lines: [TranscriptLine], turns: [SpeakerTurn]) -> [TranscriptLine] {
    guard !turns.isEmpty else { return lines }
    var numbers = [String: Int]()
    return lines.map { line in
        let end = max(line.end ?? line.start + 1, line.start)
        let overlap = { (t: SpeakerTurn) in max(0, min(end, t.end) - max(line.start, t.start)) }
        let distance = { (t: SpeakerTurn) in t.end < line.start ? line.start - t.end : max(0, t.start - end) }
        var talk = [String: TimeInterval]()
        for t in turns { talk[t.voice, default: 0] += overlap(t) }
        let voice = talk.filter { $0.value > 0 }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
            ?? turns.min { distance($0) < distance($1) }!.voice
        let number = numbers[voice] ?? (numbers.count + 1)
        numbers[voice] = number
        var labeled = line
        labeled.speaker = "Speaker \(number)"
        return labeled
    }
}

/// Meetings a quit, crash or update left mid-recording or mid-transcription, other than `current`.
public func unfinishedMeetings(_ meetings: [Meeting], except current: String?) -> [Meeting] {
    meetings.filter { ($0.status == .recording || $0.status == .transcribing) && $0.id != current }
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

    /// One meeting as saved, or nil.
    public func load(_ id: String) -> Meeting? {
        (try? Data(contentsOf: folder(for: id).appendingPathComponent("meeting.json"))).flatMap { try? Self.decoder.decode(Meeting.self, from: $0) }
    }

    /// Changes only what `change` touches on the saved meeting, so work finishing at different
    /// times (calendar lookup, transcription, summary) never overwrites each other's results.
    @discardableResult
    public func update(_ id: String, _ change: (inout Meeting) -> Void) throws -> Meeting? {
        guard var meeting = load(id) else { return nil }
        change(&meeting)
        try save(meeting)
        return meeting
    }

    /// All meetings, newest first.
    public func all() -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))).flatMap { try? Self.decoder.decode(Meeting.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }
}
