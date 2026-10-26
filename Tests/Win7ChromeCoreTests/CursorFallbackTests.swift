import AppKit
import Testing
import Win7ChromeCore
import Win7Theme

/// without imported cursors the dylib falls back to the procedural Aero cursors; imported ones win.
@Suite struct CursorFallbackTests {
    @Test func importedWinsProceduralFillsTheRest() {
        let imported = NSCursor(image: NSImage(size: NSSize(width: 8, height: 8)), hotSpot: NSPoint(x: 2, y: 3))
        let set = ["arrow": imported]
        #expect(W7CursorForKind(set, .arrow) === imported)
        #expect(W7CursorForKind(set, .ibeam) === W7ProceduralCursor(.ibeam, 0))
        #expect(W7CursorForKind([:], .arrow) === W7ProceduralCursor(.arrow, 0))
        #expect(W7CursorForKind([:], .hand).hotSpot == NSPoint(x: 10, y: 1))
    }

    /// The system cursors the dylib (and the shell) replace, and the kinds they become.
    @Test func swizzledCursorTable() {
        let table = W7SwizzledCursorKinds()
        #expect(table["arrowCursor"] == W7CursorKind.arrow.rawValue as NSNumber)
        #expect(table["IBeamCursor"] == W7CursorKind.ibeam.rawValue as NSNumber)
        #expect(table["pointingHandCursor"] == W7CursorKind.hand.rawValue as NSNumber)
        #expect(table["resizeLeftRightCursor"] == W7CursorKind.resizeEW.rawValue as NSNumber)
        #expect(table["resizeUpDownCursor"] == W7CursorKind.resizeNS.rawValue as NSNumber)
        #expect(table["crosshairCursor"] == W7CursorKind.crosshair.rawValue as NSNumber)
        #expect(table["operationNotAllowedCursor"] == W7CursorKind.notAllowed.rawValue as NSNumber)
        #expect(table.count == 11)
    }

    /// W7ProceduralCursorsDisabled: only imported cursors; the rest resolve to nil (the system cursor).
    @Test func proceduralCanBeDisabled() {
        let imported = NSCursor(image: NSImage(size: NSSize(width: 8, height: 8)), hotSpot: .zero)
        #expect(W7ResolveCursor(["hand": imported], .hand, false) === imported)
        #expect(W7ResolveCursor(["hand": imported], .arrow, false) == nil)
        #expect(W7ResolveCursor([:], .arrow, true) === W7ProceduralCursor(.arrow, 0))
    }

    /// Installs, checks, and swizzles back, so no other test sees the replaced cursors.
    @MainActor @Test func installReplacesSystemCursors() {
        _ = NSApplication.shared
        let systemArrow = NSCursor.arrow
        W7InstallCursorsWithImported([:])
        let replaced = (W7ProceduralCursorsDisabled() == false)
        let arrow = NSCursor.arrow, iBeam = NSCursor.iBeam
        let resize = NSCursor.resizeLeftRight, notAllowed = NSCursor.operationNotAllowed
        W7UninstallCursors()
        if replaced {
            #expect(iBeam === W7ProceduralCursor(.ibeam, 0))
            #expect(arrow === W7ProceduralCursor(.arrow, 0))
            #expect(resize === W7ProceduralCursor(.resizeEW, 0))
            #expect(notAllowed === W7ProceduralCursor(.notAllowed, 0))
        }
        #expect(NSCursor.arrow === systemArrow)
        #expect(NSCursor.arrow !== W7ProceduralCursor(.arrow, 0))
    }
}
