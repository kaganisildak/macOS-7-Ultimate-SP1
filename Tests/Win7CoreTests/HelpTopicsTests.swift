import Testing
import Foundation
@testable import Win7Core

/// Windows Help and Support's topics, search, links and history.
@Suite struct HelpTopicsTests {
    @Test func searchFindsInstallingTurkishInsensitive() {
        let titles = { (q: String) in HelpTopics.search(q).map(\.title) }
        #expect(titles("ins").first?.hasPrefix("Installing") == true)
        #expect(titles("İNS").first?.hasPrefix("Installing") == true)   // tr_TR capital I with dot
        #expect(titles("INS").first?.hasPrefix("Installing") == true)
        #expect(titles("ınstall").first?.hasPrefix("Installing") == true)   // dotless i
        #expect(HelpTopics.search("").isEmpty)
        #expect(HelpTopics.search("   ").isEmpty)
        #expect(HelpTopics.search("zzqx-no-such-words").isEmpty)
    }

    /// Titles rank before bodies; a body-only match is still found.
    @Test func searchRanksTitlesBeforeBodies() {
        let results = HelpTopics.search("taskbar")
        #expect(results.first?.id == "taskbar")
        let bodyOnly = HelpTopics.all.first { !AppCatalog.fold($0.title).contains("ctrl+esc") && AppCatalog.fold($0.searchText).contains("ctrl+esc") }
        #expect(bodyOnly != nil)
        #expect(HelpTopics.search("Ctrl+Esc").contains { $0.id == bodyOnly?.id })
    }

    @Test func topicsAreUniqueAndComplete() {
        let ids = HelpTopics.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(HelpTopics.all.count >= 10)
        for t in HelpTopics.all {
            #expect(!t.title.isEmpty && !t.summary.isEmpty && !t.body.isEmpty)
            #expect(HelpTopics.topic(t.id) == t)
        }
        for c in HelpCategory.allCases { #expect(!HelpTopics.topics(in: c).isEmpty) }
        #expect(HelpTopics.browse().flatMap(\.topics).count == HelpTopics.all.count)
        // The home page's own topics exist.
        for id in ["getting-started", "windows-basics", "more-support"] { #expect(HelpTopics.topic(id) != nil) }
    }

    /// Screen Resolution's "What display settings should I choose?" opens a Help topic of its own (the info
    /// page stays as the fallback).
    @Test func displaySettingsTopic() throws {
        let t = try #require(HelpTopics.topic(HelpTopics.displaySettingsTopic))
        #expect(t.title == "What display settings should I choose?")
        #expect(t.category == .settings)
        let text = AppCatalog.fold(t.searchText)
        #expect(text.contains("15 seconds") && text.contains("keep changes") && text.contains("recommended"))
        #expect(t.links.contains { $0.target == .window(.screenResolution) })
        #expect(HelpTopics.search("display settings").first?.id == HelpTopics.displaySettingsTopic)
        #expect(!ControlPanelCatalog.displaySettingsInfo.isEmpty)
    }

    /// Every link resolves: Control Panel links name a catalogue id, topic links a topic.
    @Test func topicLinksResolveToCatalogueIDs() {
        let catalog = Set(ControlPanelCatalog.items.map(\.id))
        let links = HelpTopics.allLinks
        #expect(links.contains { if case .controlPanel = $0.target { return true } else { return false } })
        for link in links {
            switch link.target {
            case .controlPanel(let id): #expect(catalog.contains(id), "unknown Control Panel id \(id)")
            case .topic(let id): #expect(HelpTopics.topic(id) != nil, "unknown topic \(id)")
            case .window, .home, .browse, .readme: break
            }
        }
    }

    @Test func homePageLinks() {
        #expect(HelpTopics.homeStartLinks.map(\.title) == [
            "How to get started with your computer", "Learn about Windows Basics", "Browse Help topics",
        ])
        #expect(HelpTopics.homeStartLinks.map(\.target) == [.topic("getting-started"), .topic("windows-basics"), .browse])
        #expect(HelpTopics.websiteLink.target == .readme)
        #expect(HelpTopics.moreSupportLink.target == .topic("more-support"))
    }

    @Test func linkURLsRoundTrip() {
        let targets: [HelpLinkTarget] = [.home, .browse, .readme, .topic("taskbar"), .controlPanel("default-programs"),
                                         .window(.deviceManager), .window(.help)]
        for t in targets { #expect(HelpLinkTarget(url: t.url) == t) }
        #expect(HelpLinkTarget(url: URL(string: "https://example.com/")!) == nil)
        #expect(HelpLinkTarget(url: URL(string: "w7help://window/nonsense")!) == nil)
        #expect(HelpLinkTarget(url: URL(string: "w7help://topic/")!) == nil)
    }

    /// Written for this project: no Microsoft wording or names in the topics.
    @Test func contentIsOurOwn() {
        for t in HelpTopics.all {
            let text = AppCatalog.fold(t.searchText)
            #expect(!text.contains("microsoft"), "\(t.id)")
            #expect(!text.contains("windows.com"), "\(t.id)")
        }
    }

    @Test func historyBackAndForward() {
        var h = HelpHistory()
        #expect(h.current == .home && !h.canGoBack && !h.canGoForward)
        let first = h.navigate(to: .topic("taskbar"))
        let again = h.navigate(to: .topic("taskbar"))
        #expect(first && !again)
        h.navigate(to: .search("ins"))
        let back = h.goBack()
        #expect(back && h.current == .topic("taskbar") && h.canGoForward)
        let forward = h.goForward()
        #expect(forward && h.current == .search("ins"))
        h.goBack()
        h.navigate(to: .browse)
        #expect(!h.canGoForward && h.current == .browse)
        h.goBack()
        h.goBack()
        let beyond = h.goBack()
        #expect(h.current == .home && !beyond)
    }
}
