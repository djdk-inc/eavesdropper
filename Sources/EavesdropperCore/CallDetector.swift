import Foundation

/// A process Core Audio reports as a client of the audio hardware.
public struct AudioProcess: Equatable, Sendable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    var isActive: Bool { isRunningInput || isRunningOutput }
}

/// Browsers whose open tabs can be read over Apple Events.
public enum Browser: String, CaseIterable, Sendable {
    case chrome, arc, edge, brave, safari

    /// Bundle ID of the app that answers Apple Events.
    public var appBundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .safari: "com.apple.Safari"
        }
    }

    /// Bundle-ID prefixes of the processes that actually play and record audio
    /// (browsers do audio in helper processes, Safari in WebKit's GPU process).
    var audioBundlePrefixes: [String] {
        switch self {
        case .safari: ["com.apple.Safari", "com.apple.WebKit"]
        default: [appBundleID]
        }
    }

    func owns(_ process: AudioProcess) -> Bool {
        audioBundlePrefixes.contains { process.bundleID.hasPrefix($0) }
    }
}

public enum CallApp: String, Codable, Sendable {
    case zoom = "Zoom"
    case meet = "Google Meet"
    /// Started from the menu: records everything the Mac plays, not one app.
    case manual = "Manual recording"
}

/// A call in progress, the audio processes carrying its sound, and the meeting tab's URL
/// (nil for the Zoom app, which exposes no URL).
public struct Call: Equatable, Sendable {
    public let app: CallApp
    public let processObjectIDs: [UInt32]
    public let meetingURL: URL?

    public init(app: CallApp, processObjectIDs: [UInt32], meetingURL: URL? = nil) {
        self.app = app
        self.processObjectIDs = processObjectIDs
        self.meetingURL = meetingURL
    }
}

let zoomBundlePrefix = "us.zoom"

/// True for a Meet room URL such as https://meet.google.com/abc-defg-hij.
public func isMeetRoom(_ url: URL) -> Bool {
    guard url.host == "meet.google.com" else { return false }
    let segments = url.pathComponents.filter { $0 != "/" }
    guard let code = segments.first, segments.count == 1 else { return false }
    let parts = code.split(separator: "-", omittingEmptySubsequences: false)
    return parts.map(\.count) == [3, 4, 3]
        && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLowercase } }
}

/// True for Zoom's in-browser meeting client, e.g. https://app.zoom.us/wc/123456789/join.
public func isZoomWebMeeting(_ url: URL) -> Bool {
    guard let host = url.host, host == "zoom.us" || host.hasSuffix(".zoom.us") else { return false }
    let segments = url.pathComponents.filter { $0 != "/" }
    return segments.first == "wc" && segments.count >= 2
}

/// The identifier a calendar invite would contain for this meeting:
/// the Meet code ("abc-defg-hij") or the Zoom meeting number ("123456789").
/// Covers Zoom links in all their forms: /j/<id>, /s/<id>, /wc/<id>/join, /wc/join/<id>.
public func meetingKey(_ url: URL) -> String? {
    if isMeetRoom(url) { return url.pathComponents.last }
    guard let host = url.host, host == "zoom.us" || host.hasSuffix(".zoom.us") else { return nil }
    let segments = url.pathComponents.filter { $0 != "/" }
    let isNumber = { (s: String) in s.count >= 9 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }
    guard let first = segments.first, ["j", "s", "w", "wc"].contains(first) else { return nil }
    return segments.dropFirst().prefix(2).first(where: isNumber)
}

/// The meeting a browser tab is in, if any.
public func meeting(at url: URL) -> CallApp? {
    if isMeetRoom(url) { return .meet }
    if isZoomWebMeeting(url) { return .zoom }
    return nil
}

/// Decides whether a Zoom or Meet call is in progress.
///
/// - Zoom app: a Zoom process is using the mic or speakers (Zoom touches audio only in a meeting).
/// - Meet or Zoom in a browser: the browser is using the mic or speakers and has a meeting tab open.
///   `tabURLs` is only called for browsers with active audio, so idle browsers are never queried.
public func detectCall(processes: [AudioProcess], tabURLs: (Browser) -> [URL]) -> Call? {
    let active = processes.filter(\.isActive)

    let zoom = active.filter { $0.bundleID.hasPrefix(zoomBundlePrefix) }
    if !zoom.isEmpty {
        return Call(app: .zoom, processObjectIDs: processes.filter { $0.bundleID.hasPrefix(zoomBundlePrefix) }.map(\.objectID))
    }

    for browser in Browser.allCases where active.contains(where: browser.owns) {
        if let url = tabURLs(browser).first(where: { meeting(at: $0) != nil }), let app = meeting(at: url) {
            return Call(app: app, processObjectIDs: processes.filter(browser.owns).map(\.objectID), meetingURL: url)
        }
    }
    return nil
}

/// Smooths detector output: a call starts after `startAfter` consecutive hits
/// and ends after `stopAfter` consecutive misses, so brief audio gaps don't split a recording.
public struct CallDebouncer {
    public private(set) var current: Call?
    private var hits = 0
    private var misses = 0
    let startAfter: Int
    let stopAfter: Int

    public init(startAfter: Int = 2, stopAfter: Int = 5) {
        self.startAfter = startAfter
        self.stopAfter = stopAfter
    }

    public enum Change: Equatable { case started(Call), ended(Call) }

    public mutating func observe(_ call: Call?) -> Change? {
        if let call {
            misses = 0
            hits += 1
            if current == nil, hits >= startAfter {
                current = call
                return .started(call)
            }
        } else {
            hits = 0
            misses += 1
            if let ended = current, misses >= stopAfter {
                current = nil
                return .ended(ended)
            }
        }
        return nil
    }
}
