// Checks for the call detector, one per route into a meeting.
// Run: swift run DetectorChecks   (exits 1 on any failure)
import EavesdropperCore
import Foundation

var failures = 0
func expect(_ ok: Bool, _ name: String, line: Int = #line) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func proc(_ id: UInt32, _ bundle: String, input: Bool = false, output: Bool = false) -> AudioProcess {
    AudioProcess(objectID: id, pid: Int32(id), bundleID: bundle, isRunningInput: input, isRunningOutput: output)
}

let meetTab = URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")!
let zoomWebTab = URL(string: "https://app.zoom.us/wc/123456789/join?pwd=x")!
let noTabs: (Browser) -> [URL] = { _ in [] }

// URL shapes
expect(isMeetRoom(meetTab), "Meet room URL")
expect(!isMeetRoom(URL(string: "https://meet.google.com/landing")!), "Meet landing page is not a room")
expect(!isMeetRoom(URL(string: "https://meet.google.com/ABC-defg-hij")!), "Meet code must be lowercase")
expect(!isMeetRoom(URL(string: "https://example.com/abc-defg-hij")!), "Meet code on another host")
expect(isZoomWebMeeting(zoomWebTab), "Zoom web client URL")
expect(isZoomWebMeeting(URL(string: "https://us02web.zoom.us/wc/123456789/start")!), "Zoom web client on regional host")
expect(!isZoomWebMeeting(URL(string: "https://us02web.zoom.us/j/123456789")!), "Zoom launcher page is not a meeting")
expect(!isZoomWebMeeting(URL(string: "https://notzoom.us/wc/1/join")!), "look-alike host")

// Route 1: Calendar → Zoom link → Zoom app
expect(detectCall(processes: [proc(1, "us.zoom.xos", input: true, output: true), proc(2, "us.zoom.xos.helper"), proc(3, "com.spotify.client", output: true)], tabURLs: noTabs)
    == Call(app: .zoom, processObjectIDs: [1, 2]), "Zoom app in a meeting; Spotify ignored")
expect(detectCall(processes: [proc(1, "us.zoom.xos", output: true)], tabURLs: noTabs)?.app == .zoom, "Zoom app, muted (speakers only)")
expect(detectCall(processes: [proc(1, "us.zoom.xos")], tabURLs: noTabs) == nil, "Zoom app open, no meeting")

// Route 2: Calendar → Zoom link → Zoom in the browser
expect(detectCall(processes: [proc(2, "com.google.Chrome.helper", input: true, output: true)]) { _ in [zoomWebTab] }
    == Call(app: .zoom, processObjectIDs: [2], meetingURL: zoomWebTab), "Zoom web client in Chrome")

// Route 3: Calendar → Meet link → Meet in the browser
expect(detectCall(processes: [proc(1, "com.google.Chrome"), proc(2, "com.google.Chrome.helper", input: true, output: true)]) {
    $0 == .chrome ? [URL(string: "https://calendar.google.com")!, meetTab] : []
} == Call(app: .meet, processObjectIDs: [1, 2], meetingURL: meetTab), "Meet in Chrome")
expect(detectCall(processes: [proc(2, "com.google.Chrome.helper", output: true)]) { _ in [meetTab] }?.app == .meet, "Meet in Chrome, muted")
expect(detectCall(processes: [proc(5, "com.apple.WebKit.GPU", input: true)]) { $0 == .safari ? [meetTab] : [] }
    == Call(app: .meet, processObjectIDs: [5], meetingURL: meetTab), "Meet in Safari (audio via WebKit)")
expect(detectCall(processes: [proc(7, "company.thebrowser.Browser.helper", output: true)]) { $0 == .arc ? [meetTab] : [] }?.app == .meet, "Meet in Arc")

// Not meetings
expect(detectCall(processes: [proc(2, "com.google.Chrome.helper", output: true)]) { _ in [URL(string: "https://youtube.com/watch?v=x")!] } == nil, "YouTube in Chrome")
expect(detectCall(processes: [proc(2, "com.google.Chrome.helper", output: true)]) { _ in [URL(string: "https://us02web.zoom.us/j/123")!] } == nil, "Zoom launcher tab while it opens the app")
var queried: [Browser] = []
_ = detectCall(processes: [proc(2, "com.google.Chrome.helper")]) { queried.append($0); return [meetTab] }
expect(queried.isEmpty, "silent browser's tabs are never read")

// Start/end timing
let call = Call(app: .zoom, processObjectIDs: [1])
var d = CallDebouncer(startAfter: 2, stopAfter: 3)
expect(d.observe(call) == nil, "one hit doesn't start")
expect(d.observe(call) == .started(call), "two hits start")
expect(d.observe(nil) == nil && d.observe(call) == nil, "a short gap doesn't end")
expect(d.observe(nil) == nil && d.observe(nil) == nil && d.observe(nil) == .ended(call), "three misses end")

// Meeting keys: what an invite would contain
expect(meetingKey(meetTab) == "abc-defg-hij", "Meet code from room URL")
expect(meetingKey(URL(string: "https://us02web.zoom.us/j/81234567890?pwd=abc#success")!) == "81234567890", "Zoom ID from launcher tab (Zoom app route)")
expect(meetingKey(zoomWebTab) == "123456789", "Zoom ID from web client")
expect(meetingKey(URL(string: "https://app.zoom.us/wc/join/81234567890")!) == "81234567890", "Zoom ID from /wc/join/<id>")
expect(meetingKey(URL(string: "https://zoom.us/pricing")!) == nil, "Zoom marketing page has no key")

// Calendar feed parsing (Google's iCal shape: folded lines, TZID, escapes, nested VALARM)
let ics = """
BEGIN:VCALENDAR\r
BEGIN:VEVENT\r
DTSTART;TZID=America/Los_Angeles:20261125T100000\r
DTEND;TZID=America/Los_Angeles:20261125T110000\r
UID:one@google.com\r
SUMMARY:Design review\\, Q4\r
ORGANIZER;CN=Pat Lee:mailto:pat@example.com\r
ATTENDEE;CUTYPE=INDIVIDUAL;CN="Lee, Pat";PARTSTAT=ACCEPTED:mailto:pat@example.com\r
ATTENDEE;CN=sam@example.com:mailto:sam@example.com\r
X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r
DESCRIPTION:Agenda:\\n1. Mocks\\n2. Launch date. Join: https://meet.google.com/abc\r
 -defg-hij\r
BEGIN:VALARM\r
DESCRIPTION:This is an event reminder\r
END:VALARM\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART:20260105T170000Z\r
DTEND:20260105T173000Z\r
RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r
UID:two@google.com\r
SUMMARY:Weekly sync\r
LOCATION:https://us02web.zoom.us/j/81234567890?pwd=abc\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART:20261125T180000Z\r
DTEND:20261125T190000Z\r
UID:three@google.com\r
SUMMARY:Coffee chat\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20261125\r
DTEND;VALUE=DATE:20261126\r
UID:four@google.com\r
SUMMARY:Out of office\r
END:VEVENT\r
END:VCALENDAR\r
"""
let events = parseICS(ics)
expect(events.count == 4, "four events parsed")
let review = events[0]
expect(review.title == "Design review, Q4", "escaped comma in title")
expect(review.start == ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z"), "TZID time converted (10:00 PT = 18:00Z)")
expect(review.organizer == "Pat Lee <pat@example.com>", "organizer name + email")
expect(review.attendees == ["Lee, Pat <pat@example.com>", "sam@example.com"], "attendees incl. quoted CN with comma")
expect(review.details == "Agenda:\n1. Mocks\n2. Launch date. Join: https://meet.google.com/abc-defg-hij", "description unescaped and unfolded; VALARM ignored")
expect(events[1].isRecurring, "RRULE marks a series")
expect(events[3].isAllDay, "all-day event")

let at = { (iso: String) in ISO8601DateFormatter().date(from: iso)! }
// Meet route: matched by code
expect(findEvent(in: events, app: .meet, meetingKey: "abc-defg-hij", at: at("2026-11-25T18:05:00Z"))?.title == "Design review, Q4", "Meet call matched by code")
// Zoom route: recurring series matched by Zoom ID from months ago
expect(findEvent(in: events, app: .zoom, meetingKey: "81234567890", at: at("2026-11-25T17:02:00Z"))?.title == "Weekly sync", "recurring Zoom matched by ID")
// No key: fall back to a one-off happening now; never the all-day event
expect(findEvent(in: events, app: .zoom, meetingKey: nil, at: at("2026-11-25T18:30:00Z"))?.title == "Design review, Q4", "no key: event with a link happening now wins")
expect(findEvent(in: events, app: .zoom, meetingKey: nil, at: at("2026-11-25T18:45:00Z")).map(\.title) != "Out of office", "all-day never matched")
expect(findEvent(in: events, app: .meet, meetingKey: "zzz-zzzz-zzz", at: at("2026-11-25T23:00:00Z")) == nil, "nothing matches → nil")

// Titles
var m = Meeting(id: "x", app: .zoom, startedAt: at("2026-11-25T18:00:00Z"), meetingURL: nil)
expect(m.title.hasPrefix("Zoom call – "), "no invite → timestamp title (\(m.title))")
m.event = review
expect(m.title == "Design review, Q4", "invite → invite title")

// Transcript merge
let merged = mergeTranscripts(you: [TranscriptLine(start: 1, speaker: "You", text: "hi"), TranscriptLine(start: 9, speaker: "You", text: "bye")],
                              others: [TranscriptLine(start: 4, speaker: "Others", text: "hello")])
expect(merged.map(\.text) == ["hi", "hello", "bye"], "both sides interleaved by time")

// Store round trip
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eavesdropper-checks-\(UUID().uuidString)")
let s2 = MeetingStore(root: dir)
m.transcript = merged
try! s2.save(m)
expect(s2.all().first?.event == review && s2.all().first?.transcript == merged, "meeting.json round trip")
try? FileManager.default.removeItem(at: dir)

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
