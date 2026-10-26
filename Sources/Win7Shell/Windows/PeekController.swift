import Foundation
import Dispatch

/// Posts the Aero Peek notifications the injected dylib listens for (no userInfo: sandboxed apps drop it).
@MainActor
final class PeekController {
    static let beginName = Notification.Name("com.win7mac.peek.begin")
    static let endName = Notification.Name("com.win7mac.peek.end")

    private(set) var isActive = false
    private var signalSources: [DispatchSourceSignal] = []

    nonisolated static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    func begin() {
        guard !isActive else { return }
        isActive = true
        Self.post(Self.beginName)
    }

    func end() {
        guard isActive else { return }
        isActive = false
        Self.post(Self.endName)
    }

    /// Always posts: used on quit, where restoring windows matters more than avoiding a redundant notification.
    func endUnconditionally() {
        isActive = false
        Self.post(Self.endName)
    }

    /// `applicationWillTerminate` does not run on SIGTERM/SIGINT, so restore windows here and exit.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                PeekController.post(PeekController.endName)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
