import Foundation

/// One VEVENT from the Google Calendar iCal feed, keeping the fields worth copying onto a meeting.
public struct CalendarEvent: Codable, Equatable, Sendable {
    public var uid = ""
    public var title = ""
    public var start: Date?
    public var end: Date?
    public var isAllDay = false
    public var organizer: String?
    public var attendees: [String] = []
    public var location: String?
    public var details: String?
    public var conferenceURL: String?
    public var status: String?
    /// True for the master of a recurring series (has an RRULE).
    public var isRecurring = false
    /// Set on a single changed occurrence of a recurring series.
    public var recurrenceID: Date?

    public init() {}

    /// All text an invite might put a meeting link in.
    var searchableText: String { [conferenceURL, location, details].compactMap { $0 }.joined(separator: "\n") }

    func overlaps(_ time: Date, slack: TimeInterval) -> Bool {
        guard let start, let end, !isAllDay else { return false }
        return start.addingTimeInterval(-slack) <= time && time <= end.addingTimeInterval(slack)
    }
}

// MARK: - iCal parsing (RFC 5545 subset)

private struct ContentLine {
    let name: String
    let params: [String: String]
    let value: String
}

/// Splits "NAME;P1=a;P2="b:c":value" at the first colon outside quotes.
private func parseLine(_ line: Substring) -> ContentLine? {
    var inQuotes = false
    var colon: Substring.Index?
    for i in line.indices {
        if line[i] == "\"" { inQuotes.toggle() }
        if line[i] == ":", !inQuotes { colon = i; break }
    }
    guard let colon else { return nil }
    var parts = [String]()
    var current = ""
    inQuotes = false
    for ch in line[..<colon] {
        if ch == "\"" { inQuotes.toggle(); continue }
        if ch == ";", !inQuotes { parts.append(current); current = ""; continue }
        current.append(ch)
    }
    parts.append(current)
    var params = [String: String]()
    for p in parts.dropFirst() {
        let kv = p.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { params[kv[0].uppercased()] = String(kv[1]) }
    }
    return ContentLine(name: parts[0].uppercased(), params: params, value: String(line[line.index(after: colon)...]))
}

private func unescapeText(_ s: String) -> String {
    var out = ""
    var escaping = false
    for ch in s {
        if escaping {
            out.append(ch == "n" || ch == "N" ? "\n" : ch)
            escaping = false
        } else if ch == "\\" {
            escaping = true
        } else {
            out.append(ch)
        }
    }
    return out
}

/// Parses DATE ("20261125") and DATE-TIME ("20261125T103000", optional "Z") values.
private func parseDate(_ line: ContentLine) -> (date: Date, allDay: Bool)? {
    let value = line.value
    let parts = value.split(separator: "T")
    let day = parts[0]
    guard day.count == 8, let y = Int(day.prefix(4)), let m = Int(day.dropFirst(4).prefix(2)), let d = Int(day.suffix(2)) else { return nil }
    var c = DateComponents(year: y, month: m, day: d)
    var tz = TimeZone.current
    let allDay = parts.count == 1
    if !allDay {
        var time = parts[1]
        if time.hasSuffix("Z") { time = time.dropLast(); tz = TimeZone(identifier: "UTC")! }
        else if let id = line.params["TZID"], let zone = TimeZone(identifier: id) { tz = zone }
        guard time.count == 6, let h = Int(time.prefix(2)), let mi = Int(time.dropFirst(2).prefix(2)), let s = Int(time.suffix(2)) else { return nil }
        c.hour = h; c.minute = mi; c.second = s
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: c).map { ($0, allDay) }
}

/// "CN=Jane Doe" + "mailto:jane@x.com" → "Jane Doe <jane@x.com>".
private func person(_ line: ContentLine) -> String {
    let email = line.value.lowercased().hasPrefix("mailto:") ? String(line.value.dropFirst(7)) : line.value
    guard let name = line.params["CN"], name != email else { return email }
    return "\(name) <\(email)>"
}

public func parseICS(_ text: String) -> [CalendarEvent] {
    // Unfold: a line starting with a space or tab continues the previous one.
    var lines = [String]()
    for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
        if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
            lines[lines.count - 1] += raw.dropFirst()
        } else {
            lines.append(String(raw))
        }
    }

    var events = [CalendarEvent]()
    var event: CalendarEvent?
    var depth = 0 // nested components inside VEVENT (VALARM) are skipped
    for raw in lines {
        guard let line = parseLine(Substring(raw)) else { continue }
        switch (line.name, line.value.uppercased()) {
        case ("BEGIN", "VEVENT"): event = CalendarEvent(); depth = 0; continue
        case ("END", "VEVENT"): if let e = event { events.append(e) }; event = nil; continue
        case ("BEGIN", _): depth += 1; continue
        case ("END", _): depth -= 1; continue
        default: break
        }
        guard event != nil, depth == 0 else { continue }
        switch line.name {
        case "UID": event!.uid = line.value
        case "SUMMARY": event!.title = unescapeText(line.value)
        case "DESCRIPTION": event!.details = unescapeText(line.value)
        case "LOCATION": event!.location = unescapeText(line.value)
        case "STATUS": event!.status = line.value
        case "X-GOOGLE-CONFERENCE": event!.conferenceURL = line.value
        case "ORGANIZER": event!.organizer = person(line)
        case "ATTENDEE": event!.attendees.append(person(line))
        case "RRULE": event!.isRecurring = true
        case "RECURRENCE-ID": event!.recurrenceID = parseDate(line)?.date
        case "DTSTART":
            if let (date, allDay) = parseDate(line) { event!.start = date; event!.isAllDay = allDay }
        case "DTEND": event!.end = parseDate(line)?.date
        default: break
        }
    }
    return events
}

// MARK: - Matching a call to its invite

/// Finds the invite for a call.
///
/// 1. By link: an event whose Meet/Zoom link carries the call's meeting key. Recurring series share one
///    link, so this finds recurring meetings too; an occurrence happening now wins over the series.
/// 2. By time: a one-off (or changed occurrence) happening now, preferring one with a link for this app.
/// Returns nil when neither finds one; the caller then titles the meeting with its start time.
public func findEvent(in events: [CalendarEvent], app: CallApp, meetingKey: String?, at now: Date) -> CalendarEvent? {
    let live = events.filter { $0.status?.uppercased() != "CANCELLED" }
    let distance = { (e: CalendarEvent) in abs((e.start ?? .distantPast).timeIntervalSince(now)) }

    if let key = meetingKey {
        let linked = live.filter { $0.searchableText.contains(key) }
        if let happening = linked.filter({ $0.overlaps(now, slack: 30 * 60) }).min(by: { distance($0) < distance($1) }) {
            return happening
        }
        if let series = linked.first(where: \.isRecurring) { return series }
        if let nearest = linked.min(by: { distance($0) < distance($1) }) { return nearest }
    }

    let host = app == .zoom ? "zoom.us" : "meet.google.com"
    let now15 = live.filter { !$0.isRecurring && $0.overlaps(now, slack: 15 * 60) }
    return now15.filter { $0.searchableText.contains(host) }.min(by: { distance($0) < distance($1) })
        ?? now15.min(by: { distance($0) < distance($1) })
}

// MARK: - Calendar snapshot (helper → recorder, one way)

/// What the calendar helper hands the sandboxed recorder: invite metadata only, never audio or transcripts.
public struct CalendarSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var events: [CalendarEvent]

    public init(fetchedAt: Date, events: [CalendarEvent]) {
        self.fetchedAt = fetchedAt
        self.events = events
    }

    /// The only events matching can use: recurring series (matched by link, any date) and
    /// one-off events within two days of now. Keeps the hand-off small.
    public static func relevant(_ events: [CalendarEvent], around now: Date) -> [CalendarEvent] {
        events.filter { event in
            guard event.status?.uppercased() != "CANCELLED" else { return false }
            if event.isRecurring { return true }
            guard let start = event.start else { return false }
            return abs(start.timeIntervalSince(now)) <= 2 * 24 * 3600
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CalendarSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CalendarSnapshot.self, from: data)
    }
}

/// Where the helper writes the snapshot, relative to the user's real home folder. The sandboxed
/// recorder may read (never write) this one folder; see Eavesdropper.entitlements.
public let calendarSnapshotRelativePath = "Library/Application Support/Eavesdropper Calendar/calendar.json"

/// The user's real home folder, even inside the App Sandbox (where NSHomeDirectory is the container).
public func realHomeDirectory() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

public var calendarSnapshotURL: URL { realHomeDirectory().appendingPathComponent(calendarSnapshotRelativePath) }
