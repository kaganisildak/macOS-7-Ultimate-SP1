import AppKit

// Win7RenderTool <outDir>: renders each Windows 7 component at 2× scale to <outDir>/<name>.png.
let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: Win7RenderTool <outDir>\n".data(using: .utf8)!)
    exit(2)
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do {
        for url in try Renderer.renderAll(to: URL(fileURLWithPath: args[1])) { print(url.path) }
    } catch {
        FileHandle.standardError.write("Win7RenderTool: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
