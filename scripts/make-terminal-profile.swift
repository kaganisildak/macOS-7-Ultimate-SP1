// Writes the "Win7 Command Prompt" Terminal profile (a .terminal plist) with the Windows 7 console colours.
// Run with the Command Line Tools' swift interpreter:
//   swift scripts/make-terminal-profile.swift <out.terminal> <cmd-zsh dir>
//       Colours and the font are NSKeyedArchiver data, as Terminal stores them. When the login shell is zsh,
//       CommandString starts it with ZDOTDIR=<cmd-zsh dir> (the Command Prompt style prompt) while that directory
//       is installed; otherwise the profile has no CommandString and Terminal runs the login shell as usual.
//   swift scripts/make-terminal-profile.swift --describe <plist> [<profile name>]
//       Prints a profile (a .terminal file, or the named entry of a Terminal preferences export's
//       "Window Settings") as sorted key=value lines, colours as #RRGGBB@alpha in sRGB. Used by the tests.
// Environment: W7_LOGIN_SHELL overrides the login shell (default: the user's shell from the user database).
import AppKit
import CoreText

let profileName = "Win7 Command Prompt"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-terminal-profile: \(message)\n".utf8))
    exit(1)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func archive(_ object: NSObject) -> Data {
    do { return try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true) }
    catch { fail("cannot archive \(object): \(error)") }
}

// Lucida Console when installed (the asset importer copies lucon.ttf into ~/Library/Fonts); a font copied
// moments ago may not be registered yet, so the file is registered for this process before giving up.
func consoleFont() -> NSFont {
    let size: CGFloat = 12
    if let font = NSFont(name: "LucidaConsole", size: size) { return font }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    for dir in ["\(home)/Library/Fonts", "/Library/Fonts"] {
        let url = URL(fileURLWithPath: "\(dir)/lucon.ttf")
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let font = NSFont(name: "LucidaConsole", size: size) { return font }
    }
    guard let menlo = NSFont(name: "Menlo-Regular", size: size) else { fail("Menlo is missing") }
    return menlo
}

func loginShell() -> String {
    if let shell = ProcessInfo.processInfo.environment["W7_LOGIN_SHELL"] { return shell }
    if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
    return ProcessInfo.processInfo.environment["SHELL"] ?? ""
}

// A single-quoted shell word.
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func makeProfile(cmdZshDir: String) -> [String: Any] {
    var p: [String: Any] = [
        "name": profileName,
        "type": "Window Settings",
        "ProfileCurrentVersion": 2.09,
        "BackgroundColor": archive(color(0x000000)),
        "TextColor": archive(color(0xC0C0C0)),
        "TextBoldColor": archive(color(0xFFFFFF)),
        "SelectionColor": archive(color(0xC0C0C0, alpha: 0.5)),
        "CursorColor": archive(color(0xC0C0C0)),
        "CursorType": 1,             // underline
        "CursorBlink": true,
        "Font": archive(consoleFont()),
        "FontAntialias": true,
        "columnCount": 80,
        "rowCount": 25,
        "WindowTitle": "Command Prompt",
    ]
    let ansi: [(String, UInt32)] = [
        ("Black", 0x000000), ("Red", 0x800000), ("Green", 0x008000), ("Yellow", 0x808000),
        ("Blue", 0x000080), ("Magenta", 0x800080), ("Cyan", 0x008080), ("White", 0xC0C0C0),
        ("BrightBlack", 0x808080), ("BrightRed", 0xFF0000), ("BrightGreen", 0x00FF00), ("BrightYellow", 0xFFFF00),
        ("BrightBlue", 0x0000FF), ("BrightMagenta", 0xFF00FF), ("BrightCyan", 0x00FFFF), ("BrightWhite", 0xFFFFFF),
    ]
    for (name, hex) in ansi { p["ANSI\(name)Color"] = archive(color(hex)) }
    // Only the custom title: no profile name, process, working directory, shell path, size, tty or ⌘-key.
    for key in ["ShowWindowSettingsNameInTitle", "ShowActiveProcessInTitle", "ShowActiveProcessArgumentsInTitle",
                "ShowRepresentedURLInTitle", "ShowRepresentedURLPathInTitle", "ShowShellCommandInTitle",
                "ShowDimensionsInTitle", "ShowTTYNameInTitle", "ShowCommandKeyInTitle",
                "ShowActiveProcessInTabTitle", "ShowActiveProcessArgumentsInTabTitle",
                "ShowRepresentedURLInTabTitle", "ShowRepresentedURLPathInTabTitle", "ShowTTYNameInTabTitle"] {
        p[key] = false
    }
    let shell = loginShell()
    if (shell as NSString).lastPathComponent == "zsh" {
        // ZDOTDIR only while cmd-zsh is installed, so a profile left behind still opens a normal login shell.
        // /usr/bin/env comes first so it also works if Terminal runs the command as "exec -la <name> <command>".
        // RunCommandAsShell must be false: with "run inside shell" Terminal splits the command at blanks and
        // ignores the quotes (measured on macOS 27: sh gets '[ as its script and -r as $0); without it the quoted
        // words arrive intact. The script execs the login shell itself, so nothing is lost.
        let script = "[ -r \"$1/.zshenv\" ] && export ZDOTDIR=\"$1\"; exec \"$2\" -l"
        p["CommandString"] = "/usr/bin/env /bin/sh -c \(shellQuoted(script)) sh \(shellQuoted(cmdZshDir)) \(shellQuoted(shell))"
        p["RunCommandAsShell"] = false
        // The window was started with a command, so Terminal would ask "terminate zsh?" on close; a shell alone is
        // no reason to ask (Terminal's own rule for the windows it opens). Anything else running still asks.
        p["noWarnProcesses"] = ["login", "sh", "-sh", "zsh", "-zsh", "bash", "-bash", "screen", "tmux"].map { ["ProcessName": $0] }
    }
    return p
}

func describe(_ value: Any) -> String {
    if let data = value as? Data {
        let classes = [NSColor.self, NSFont.self]
        if let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) {
            if let c = (object as? NSColor)?.usingColorSpace(.sRGB) {
                let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
                return String(format: "#%02X%02X%02X@%g", v[0], v[1], v[2], Double(c.alphaComponent))
            }
            if let f = object as? NSFont { return "\(f.fontName) \(Int(f.pointSize))" }
        }
        return "<data \(data.count)>"
    }
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
    if let a = value as? [Any] { return "[" + a.map(describe).joined(separator: ", ") + "]" }
    if let d = value as? [String: Any] { return d.keys.sorted().map { "\($0)=\(describe(d[$0]!))" }.joined(separator: ";") }
    return "\(value)"
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--describe" {
    guard args.count == 2 || args.count == 3 else { fail("usage: --describe <plist> [<profile name>]") }
    guard let data = FileManager.default.contents(atPath: args[1]),
          let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { fail("cannot read \(args[1])") }
    var profile = root
    if args.count == 3 {
        guard let all = root["Window Settings"] as? [String: Any], let named = all[args[2]] as? [String: Any]
        else { fail("no profile \"\(args[2])\" in \(args[1])") }
        profile = named
    }
    for key in profile.keys.sorted() { print("\(key)=\(describe(profile[key]!))") }
    exit(0)
}

guard args.count == 2 else { fail("usage: <out.terminal> <cmd-zsh dir> | --describe <plist> [<profile name>]") }
let out = URL(fileURLWithPath: args[0])
do {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: makeProfile(cmdZshDir: args[1]),
                                                  format: .xml, options: 0)
    try data.write(to: out, options: .atomic)
} catch {
    fail("cannot write \(out.path): \(error)")
}
