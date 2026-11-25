import AppKit
import AVFoundation
import EavesdropperCore
import SwiftUI

func log(_ message: String) {
    FileHandle.standardError.write(Data("[eavesdropper] \(message)\n".utf8))
}

let store = MeetingStore(root: FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Recordings/Eavesdropper", isDirectory: true))

/// The URL of the call: the meeting tab for browser calls; for the Zoom app, the
/// zoom.us/j/<id> tab the calendar link opened before handing off to the app.
func meetingURL(for call: Call) -> URL? {
    if let url = call.meetingURL { return url }
    guard call.app == .zoom else { return nil }
    return Browser.allCases.lazy.flatMap(openTabURLs).first { meetingKey($0) != nil && $0.host?.hasSuffix("zoom.us") == true }
}

/// Fills in the invite (if one matches) for a meeting that just started.
func attachCalendarEvent(to meeting: Meeting) async -> Meeting {
    var meeting = meeting
    let key = meeting.meetingURL.flatMap(URL.init(string:)).flatMap(meetingKey)
    meeting.event = findEvent(in: await fetchCalendarEvents(), app: meeting.app, meetingKey: key, at: meeting.startedAt)
    log("title: \(meeting.title)")
    return meeting
}

/// Transcribes both sides of a finished meeting into one interleaved transcript.
func transcribeMeeting(_ meeting: Meeting) async -> Meeting {
    var meeting = meeting
    let folder = store.folder(for: meeting.id)
    do {
        async let you = transcribe(folder.appendingPathComponent("mic.m4a"), speaker: "You")
        async let others = transcribe(folder.appendingPathComponent("call.m4a"), speaker: "Others")
        meeting.transcript = mergeTranscripts(you: try await you, others: try await others)
        meeting.status = .done
    } catch {
        meeting.status = .failed
        meeting.error = "\(error)"
    }
    log("transcript: \(meeting.transcript.count) lines, \(meeting.status.rawValue)")
    return meeting
}

// MARK: - Command-line modes for checking pieces on their own

let args = CommandLine.arguments

/// `--probe`: print what the detector sees right now.
if args.contains("--probe") {
    for p in audioProcesses() where p.isRunningInput || p.isRunningOutput {
        print("audio  pid=\(p.pid) \(p.bundleID) input=\(p.isRunningInput) output=\(p.isRunningOutput)")
    }
    for browser in Browser.allCases {
        for url in openTabURLs(browser) where meetingKey(url) != nil {
            print("tab    \(browser.rawValue) \(url.host ?? "")\(url.path)")
        }
    }
    let call = detectCall(processes: audioProcesses(), tabURLs: openTabURLs)
    print("call   \(call.map { "\($0.app.rawValue) (\($0.processObjectIDs.count) audio processes)" } ?? "none")")
    exit(0)
}

/// `--transcribe <audio file>`: print the on-device transcript of a file.
if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    Task {
        do {
            for line in try await transcribe(URL(fileURLWithPath: args[i + 1]), speaker: "Speaker") {
                print(String(format: "[%6.1fs] ", line.start) + line.text)
            }
            exit(0)
        } catch {
            print("transcription failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

/// `--record <pid> <seconds> <folder>`: record one process's sound plus the mic, as during a call.
if let i = args.firstIndex(of: "--record"), i + 3 < args.count, let pid = Int32(args[i + 1]), let seconds = Double(args[i + 2]) {
    let ids = audioProcesses().filter { $0.pid == pid }.map(\.objectID)
    guard !ids.isEmpty else { print("pid \(pid) has no audio"); exit(1) }
    let recorder = try CallRecorder(call: Call(app: .zoom, processObjectIDs: ids), folder: URL(fileURLWithPath: args[i + 3]))
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        recorder.stop()
        print("recorded to \(recorder.folder.path)")
        exit(0)
    }
    RunLoop.main.run()
}

/// `--calendar [meeting URL]`: fetch the calendar and print which invite a call at that URL, now, would get.
if let i = args.firstIndex(of: "--calendar") {
    let url = i + 1 < args.count ? URL(string: args[i + 1]) : nil
    Task {
        let events = await fetchCalendarEvents()
        let app: CallApp = url?.host == "meet.google.com" ? .meet : .zoom
        let event = findEvent(in: events, app: app, meetingKey: url.flatMap(meetingKey), at: Date())
        print("events \(events.count)")
        print("match  \(event.map { "\($0.title) | organizer=\($0.organizer ?? "-") | attendees=\($0.attendees.count)" } ?? "none (timestamp title)")")
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - Menu bar app

/// Polls for a Zoom/Meet call, records it while it lasts, then transcribes it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Waiting for a call", action: nil, keyEquivalent: "")
    private let list = MeetingList(store: store)
    private var window: NSWindow?
    private var debouncer = CallDebouncer()
    private var recorder: CallRecorder?
    private var meeting: Meeting?

    func applicationDidFinishLaunching(_: Notification) {
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Transcripts", action: #selector(showTranscripts), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Quit Eavesdropper", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        render()

        AVCaptureDevice.requestAccess(for: .audio) { granted in log("microphone access: \(granted)") }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.poll() } }
        log("watching for Zoom and Google Meet calls; meetings go to \(store.root.path)")
    }

    private func poll() {
        switch debouncer.observe(detectCall(processes: audioProcesses(), tabURLs: openTabURLs)) {
        case let .started(call)?: start(call)
        case .ended?: end()
        case nil: break
        }
        render()
    }

    private func start(_ call: Call) {
        let now = Date()
        let id = "\(now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))) \(call.app.rawValue)"
        let new = Meeting(id: id, app: call.app, startedAt: now, meetingURL: meetingURL(for: call)?.absoluteString)
        meeting = new
        save(new)
        log("\(call.app.rawValue) call started → \(store.folder(for: id).path)")
        do {
            recorder = try CallRecorder(call: call, folder: store.folder(for: id))
        } catch {
            log("could not start recording: \(error)")
        }
        Task {
            let withEvent = await attachCalendarEvent(to: new)
            guard meeting?.id == id else { return save(withEvent) } // call already ended
            meeting?.event = withEvent.event
            save(meeting!)
        }
    }

    private func end() {
        guard var finished = meeting else { return }
        recorder?.stop()
        recorder = nil
        meeting = nil
        finished.endedAt = Date()
        finished.status = .transcribing
        save(finished)
        log("\(finished.app.rawValue) call ended; transcribing")
        let id = finished.id
        Task {
            // Pick up the calendar match if it landed after the call ended.
            if let latest = store.all().first(where: { $0.id == id }) { finished.event = latest.event }
            save(await transcribeMeeting(finished))
        }
    }

    private func save(_ meeting: Meeting) {
        do { try store.save(meeting) } catch { log("save failed: \(error)") }
        list.reload()
    }

    private func render() {
        if let meeting {
            statusItem.button?.image = spyIcon(listening: true)
            statusLine.title = "Listening: \(meeting.title)"
        } else {
            statusItem.button?.image = spyIcon(listening: false)
            statusLine.title = "Waiting for a call"
        }
    }

    @objc private func showTranscripts() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: TranscriptsView(list: list)))
            w.title = "Eavesdropper"
            w.setContentSize(NSSize(width: 900, height: 600))
            w.isReleasedWhenClosed = false
            window = w
        }
        list.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func quit() {
        if meeting != nil { end() }
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
