import EavesdropperCore
import Foundation

/// Reads the Google Calendar private iCal URL from Secret Manager with your gcloud login
/// (nothing stored on disk), then fetches the feed. Any failure returns [] and the
/// meeting keeps its timestamp title.
func fetchCalendarEvents() async -> [CalendarEvent] {
    do {
        guard let url = URL(string: try readSecret("GOOGLE_CALENDAR_ICS_URL")) else { throw CalendarError("secret is not a URL") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CalendarError("feed returned \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        let events = parseICS(String(decoding: data, as: UTF8.self))
        log("calendar: \(events.count) events")
        return events
    } catch {
        log("calendar unavailable, using timestamp title: \(error)")
        return []
    }
}

struct CalendarError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private let gcloudPaths = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "/usr/bin/gcloud"]

private func readSecret(_ name: String) throws -> String {
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
