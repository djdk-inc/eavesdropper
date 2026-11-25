import AppKit
import EavesdropperCore

/// The calendar helper, bundled at Contents/Helpers. It is the only part of Eavesdropper with
/// network access; the recorder only ever reads the metadata snapshot it writes.
var calendarHelperURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Eavesdropper Calendar.app", isDirectory: true)
}

func readCalendarSnapshot() -> CalendarSnapshot? {
    (try? Data(contentsOf: calendarSnapshotURL)).flatMap { try? CalendarSnapshot.decode($0) }
}

/// Invite metadata for matching a call: asks the helper for a fresh snapshot (waiting up to 30 s),
/// falling back to one under a day old, else none (the meeting keeps its timestamp title).
func calendarEvents() async -> [CalendarEvent] {
    let asked = Date()
    if FileManager.default.fileExists(atPath: calendarHelperURL.path) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: calendarHelperURL, configuration: configuration)
            for _ in 0..<30 {
                if let snapshot = readCalendarSnapshot(), snapshot.fetchedAt >= asked.addingTimeInterval(-5) { return snapshot.events }
                try? await Task.sleep(for: .seconds(1))
            }
            log("calendar helper didn't answer in 30 s")
        } catch {
            log("couldn't launch calendar helper: \(error)")
        }
    }
    if let snapshot = readCalendarSnapshot(), Date().timeIntervalSince(snapshot.fetchedAt) < 24 * 3600 {
        log("using calendar snapshot from \(snapshot.fetchedAt)")
        return snapshot.events
    }
    log("no calendar snapshot; timestamp title")
    return []
}

/// "0.2.0 (build 12, abc1234)" from the Info.plist values build-app.sh stamps.
var versionDescription: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info["CFBundleVersion"] as? String ?? "?"
    let commit = info["EavesdropperCommit"] as? String ?? "?"
    return "\(version) (build \(build), \(commit))"
}
