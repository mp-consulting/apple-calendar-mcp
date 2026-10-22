import AppKit

extension NSWorkspace {
    /// Shows Calendar links (`Event.calendarLinks`). They go in one request, so Calendar handles them in order (it
    /// must show an occurrence's day before the occurrence link can find it). Calendar drops an occurrence link that
    /// arrives before the new day's events are loaded, so the last link goes again a moment later. Returns once the
    /// requests are delivered: a process that exits sooner (`apple-calendar-mcp call`) would drop them.
    @discardableResult
    public func showInCalendar(_ links: [String]) async -> Bool {
        let urls = links.compactMap(URL.init(string:))
        guard let last = urls.last, let app = urlForApplication(toOpen: last) else { return false }
        guard (try? await open(urls, withApplicationAt: app, configuration: OpenConfiguration())) != nil else { return false }
        if urls.count > 1 {
            try? await Task.sleep(for: .milliseconds(500))
            _ = try? await open([last], withApplicationAt: app, configuration: OpenConfiguration())
        }
        return true
    }
}
