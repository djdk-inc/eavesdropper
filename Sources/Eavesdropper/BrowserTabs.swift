import AppKit
import EavesdropperCore

/// URLs of every open tab in `browser`, read over Apple Events.
/// Returns [] when the browser isn't running, so the query never launches it.
func openTabURLs(_ browser: Browser) -> [URL] {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.appBundleID).isEmpty else { return [] }
    let source = "tell application id \"\(browser.appBundleID)\" to get URL of every tab of every window"
    var error: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
        if let error { log("tab query for \(browser.rawValue) failed: \(error)") }
        return []
    }
    return flatStrings(result).compactMap(URL.init(string:))
}

/// The result is a list (windows) of lists (tabs) of strings.
private func flatStrings(_ descriptor: NSAppleEventDescriptor) -> [String] {
    guard descriptor.numberOfItems > 0 else { return descriptor.stringValue.map { [$0] } ?? [] }
    return (1...descriptor.numberOfItems).flatMap { i in descriptor.atIndex(i).map(flatStrings) ?? [] }
}
