// Eavesdropper Calendar: the only part of Eavesdropper with network access.
//
// Reads the Google Calendar private iCal URL from Secret Manager with your gcloud login (never stored),
// fetches the feed, keeps the invites meeting-matching can use, writes them to calendarSnapshotURL, exits.
// It never sees audio or transcripts: those live in the recorder's sandbox container, which macOS
// keeps other apps out of.
import EavesdropperCore
import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data("[eavesdropper-calendar] \(message)\n".utf8))
}

struct CalendarError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let gcloudPaths = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "/usr/bin/gcloud"]

func readSecret(_ name: String) throws -> String {
    guard let gcloud = gcloudPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw CalendarError("gcloud not found") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gcloud)
    process.arguments = ["secrets", "versions", "access", "latest", "--secret", name, "--project", "djdk-inc"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CalendarError("gcloud exited \(process.terminationStatus)") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func fetchEvents() async throws -> [CalendarEvent] {
    guard let url = URL(string: try readSecret("GOOGLE_CALENDAR_ICS_URL")) else { throw CalendarError("secret is not a URL") }
    let (data, response) = try await URLSession.shared.data(from: url)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw CalendarError("feed returned \(status)") }
    return parseICS(String(decoding: data, as: UTF8.self))
}

let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        let now = Date()
        let all = try await fetchEvents()
        let snapshot = CalendarSnapshot(fetchedAt: now, events: CalendarSnapshot.relevant(all, around: now))
        let url = calendarSnapshotURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapshot.encoded().write(to: url, options: .atomic)
        log("wrote \(snapshot.events.count) of \(all.count) events to \(url.path)")
    } catch {
        log("calendar unavailable: \(error)")
        exitCode = 1
    }
    done.signal()
}
done.wait()
exit(exitCode)
