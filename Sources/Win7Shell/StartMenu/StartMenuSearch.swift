import AppKit
import Win7ChromeCore
import Win7Core

/// The file half of the Start menu search: a Spotlight query (NSMetadataQuery) on display names in
/// the home folder, started 150 ms after the last keystroke. A new text stops the previous query. Only
/// Spotlight's index is read, so no file is opened and no privacy prompt appears. The query gathers and
/// its results are read on a background queue; only the capped hits come back to the main actor.
@MainActor
final class StartMenuFileSearch: NSObject {
    /// Called with the hits for `text` once its query has gathered.
    var onResults: (() -> Void)?
    /// The text `results` belong to.
    private(set) var resultsText = ""
    private(set) var results: [FileHit] = []

    private var pendingText = ""
    private var timer: Timer?
    private let runner = SpotlightNameQuery()
    /// Bumped by every start and stop, so a late answer from a replaced query is dropped.
    private var queryID = 0

    /// Starts (after the debounce) a search for `text`; an empty text stops searching.
    func update(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != pendingText else { return }
        pendingText = t
        stopQuery()
        timer?.invalidate()
        timer = nil
        guard !t.isEmpty else {
            resultsText = ""
            results = []
            return
        }
        timer = Timer.w7Scheduled(StartMenuSearchResults.debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startQuery() }
        }
    }

    func cancel() { update("") }

    private func startQuery() {
        let text = pendingText
        guard !text.isEmpty else { return }
        queryID += 1
        let id = queryID
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        runner.start(text: text, home: home) { [weak self] hits in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.queryID == id else { return }
                    // nil: Spotlight is off or unavailable; the search ends with no files, so "No items
                    // match" can show.
                    self.resultsText = text
                    self.results = hits ?? []
                    self.onResults?()
                }
            }
        }
    }

    private func stopQuery() {
        queryID += 1
        runner.stop()
    }

    // MARK: See more results

    /// Opens a Finder search window for `text` over the home folder: a `.savedSearch` written to
    /// ~/Library/Application Support/Win7Mac/Searches (stale ones are removed after a day).
    static func openMoreResults(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Win7Mac/Searches")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Win7Search-\(UUID().uuidString).savedSearch")
            try W7SavedSearchPlist(query, fm.homeDirectoryForCurrentUser.path).write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("Win7Shell: saved search failed: \(error)")
        }
        let path = dir.path
        DispatchQueue.global(qos: .utility).async { _ = W7RemoveStaleSavedSearches(path, Date()) }
    }
}

/// One Spotlight display-name query at a time, run entirely on its own serial queue: NSMetadataQuery
/// gathers on its `operationQueue`, so neither the gathering nor the result walk touch the main thread.
/// All mutable state is only touched on `queue`.
private final class SpotlightNameQuery: @unchecked Sendable {
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.win7mac.shell.file-search"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private var query: NSMetadataQuery?
    private var token: NSObjectProtocol?

    /// Replaces any running query. `deliver` runs on the query's queue with the capped hits, or nil
    /// when Spotlight does not start.
    func start(text: String, home: String, deliver: @escaping @Sendable ([FileHit]?) -> Void) {
        queue.addOperation { [self] in
            stopOnQueue()
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey,
                                      StartMenuSearchResults.likePattern(text))
            q.searchScopes = [NSMetadataQueryUserHomeScope]
            q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
            q.operationQueue = queue
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q,
                                                           queue: queue) { [weak self] note in
                guard let self, let q = self.query, (note.object as AnyObject?) === q else { return }
                let hits = ShellPerf.measure("fileSearchGather") { Self.hits(q, home: home) }
                self.stopOnQueue()
                deliver(hits)
            }
            query = q
            if !q.start() {
                stopOnQueue()
                deliver(nil)
            }
        }
    }

    func stop() {
        queue.addOperation { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        query?.stop()
        query = nil
    }

    private static func hits(_ q: NSMetadataQuery, home: String) -> [FileHit] {
        q.disableUpdates()
        var hits: [FileHit] = []
        var i = 0
        // Spotlight can return thousands of items for a short text; stop at the cap.
        while i < q.resultCount, hits.count < StartMenuSearchResults.fileQueryLimit {
            defer { i += 1 }
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  StartMenuSearchResults.isListable(path: path, home: home) else { continue }
            let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                ?? (path as NSString).lastPathComponent
            hits.append(FileHit(name: name, path: path, kind: StartMenuSearchResults.kind(contentTypeTree: tree),
                                contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String))
        }
        return hits
    }
}
