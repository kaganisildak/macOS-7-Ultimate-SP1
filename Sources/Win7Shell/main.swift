import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Win7Core

// Headless helper used by scripts/install.sh: --write-default-wallpaper <path>
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--write-default-wallpaper") {
    guard i + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: Win7Shell --write-default-wallpaper <path>\n".utf8))
        exit(2)
    }
    exit(DefaultWallpaper.write(to: args[i + 1]) ? 0 : 1)
}

// Headless permission probe used by scripts/setup.sh: prints the Accessibility and Screen Recording grant
// state (the same two checks as PermissionPoller) and exits, never prompting. TCC answers for the responsible
// process, so setup.sh launches this through LaunchServices (`open`): run from Terminal directly it would
// report Terminal's grants, not Win7Shell's.
if args.contains("--w7-permission-probe") {
    let state = PermissionGate(
        // "AXTrustedCheckOptionPrompt" is kAXTrustedCheckOptionPrompt's value; Swift 6 rejects the C global itself.
        isAXTrusted: { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) },
        hasScreenCapture: { CGPreflightScreenCaptureAccess() }).snapshot()
    print("accessibility=\(state.axTrusted ? 1 : 0)")
    print("screen-recording=\(state.screenCapture ? 1 : 0)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
StartupSound.playIfLogin()
app.run()
