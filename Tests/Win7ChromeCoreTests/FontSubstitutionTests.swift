import AppKit
import CoreText
import ObjectiveC
import Testing
import Win7ChromeCore

/// Segoe UI in place of the system font, only when the user imported it.
@Suite(.serialized) struct FontSubstitutionTests {
    @Test func weightToFace() {
        #expect(!W7FontSubstitutionUsesBoldFace(NSFont.Weight.regular.rawValue))
        #expect(!W7FontSubstitutionUsesBoldFace(NSFont.Weight.medium.rawValue))
        #expect(W7FontSubstitutionUsesBoldFace(NSFont.Weight.semibold.rawValue))
        #expect(W7FontSubstitutionUsesBoldFace(NSFont.Weight.bold.rawValue))
        #expect(W7FontSubstitutionUsesBoldFace(NSFont.Weight.black.rawValue))
        #expect(!W7FontSubstitutionUsesBoldFace(NSFont.Weight.light.rawValue))
        #expect(W7FontSubstitutionFaceName(NSFont.Weight.regular.rawValue, "SegoeUI", "SegoeUI-Bold") == "SegoeUI")
        #expect(W7FontSubstitutionFaceName(NSFont.Weight.bold.rawValue, "SegoeUI", "SegoeUI-Bold") == "SegoeUI-Bold")
        #expect(W7FontSubstitutionFaceName(NSFont.Weight.bold.rawValue, "SegoeUI", nil) == nil, "no bold face: system bold")
        #expect(W7FontSubstitutionFaceName(NSFont.Weight.regular.rawValue, nil, "SegoeUI-Bold") == nil)
    }

    @Test func substitutionRules() {
        #expect(W7ShouldSubstituteSystemFont(13, false, true, false))
        #expect(W7ShouldSubstituteSystemFont(9, false, true, false))
        #expect(!W7ShouldSubstituteSystemFont(8.5, false, true, false), "under 9 pt")
        #expect(!W7ShouldSubstituteSystemFont(13, true, true, false), "monospaced")
        #expect(!W7ShouldSubstituteSystemFont(13, false, false, false), "dark appearance")
        #expect(!W7ShouldSubstituteSystemFont(13, false, true, true), "kill switch")
        #expect(W7FontSubstitutionAppliesToBundlePath("/System/Applications/TextEdit.app"))
        #expect(W7FontSubstitutionAppliesToBundlePath("/Applications/Foo.APP"))
        #expect(!W7FontSubstitutionAppliesToBundlePath("/Applications/Foo.app/Contents/PlugIns/Share.appex"))
        #expect(!W7FontSubstitutionAppliesToBundlePath("/usr/libexec"))
        #expect(!W7FontSubstitutionAppliesToBundlePath(nil))
        #expect(W7FontSubstitutionFontDirectory().hasSuffix("/Library/Application Support/Win7Mac/Assets/fonts"))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w7fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func postScriptName(_ url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }

    private func systemFontIMP() -> IMP? {
        class_getClassMethod(NSFont.self, #selector(NSFont.systemFont(ofSize:))).map { method_getImplementation($0) }
    }

    /// One test, in order: without the font nothing is swizzled; with a stub font (a system TTF copied in as
    /// segoeui.ttf/segoeuib.ttf) the system font methods return it, except for monospaced, small, dark and
    /// disabled requests. Substitution is turned off again at the end, so other tests see the system font.
    @MainActor @Test func installsOnlyWithTheImportedFont() throws {
        W7FontSubstitutionUseDisabledOverride(0)
        W7FontSubstitutionUseLightOverride(1)
        defer {
            W7FontSubstitutionDeactivate()
            W7FontSubstitutionUseDisabledOverride(-1)
            W7FontSubstitutionUseLightOverride(-1)
        }
        // No font: nothing registered, nothing swizzled.
        let empty = try tempDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        let before = systemFontIMP()
        #expect(!W7FontSubstitutionInstallFromDirectory(empty.path))
        #expect(!W7FontSubstitutionIsSwizzled())
        #expect(!W7FontSubstitutionIsActive())
        #expect(systemFontIMP() == before, "+systemFontOfSize: untouched")
        // A file that is not a font counts as missing.
        try Data("not a font".utf8).write(to: empty.appendingPathComponent("segoeui.ttf"))
        #expect(!W7FontSubstitutionInstallFromDirectory(empty.path))
        #expect(!W7FontSubstitutionIsSwizzled())

        // A stub font under the imported names.
        let supplemental = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental")
        let regularSource = supplemental.appendingPathComponent("Georgia.ttf")
        let boldSource = supplemental.appendingPathComponent("Georgia Bold.ttf")
        try #require(FileManager.default.fileExists(atPath: regularSource.path), "stub font source")
        let stub = try tempDir()
        defer { try? FileManager.default.removeItem(at: stub) }
        try FileManager.default.copyItem(at: regularSource, to: stub.appendingPathComponent("segoeui.ttf"))
        try FileManager.default.copyItem(at: boldSource, to: stub.appendingPathComponent("segoeuib.ttf"))
        let regular = try #require(postScriptName(stub.appendingPathComponent("segoeui.ttf")))
        let bold = try #require(postScriptName(stub.appendingPathComponent("segoeuib.ttf")))
        #expect(regular != bold)

        let systemName = NSFont.systemFont(ofSize: 13).fontName
        #expect(W7FontSubstitutionInstallFromDirectory(stub.path))
        #expect(W7FontSubstitutionIsSwizzled() && W7FontSubstitutionIsActive())
        #expect(systemFontIMP() != before)

        let substituted = NSFont.systemFont(ofSize: 13)
        #expect(substituted.fontName == regular && substituted.pointSize == 13)
        #expect(NSFont.systemFont(ofSize: 13) === substituted, "cached per size and weight")
        #expect(NSFont.boldSystemFont(ofSize: 13).fontName == bold)
        #expect(NSFont.systemFont(ofSize: 12, weight: .semibold).fontName == bold)
        #expect(NSFont.systemFont(ofSize: 12, weight: .medium).fontName == regular)
        for f in [NSFont.messageFont(ofSize: 12), NSFont.menuFont(ofSize: 12), NSFont.labelFont(ofSize: 10),
                  NSFont.controlContentFont(ofSize: 11)] {
            #expect(f.fontName == regular, "\(f)")
        }
        #expect(NSFont.systemFont(ofSize: 0).fontName == regular, "the default size")
        #expect([regular, bold].contains(NSFont.titleBarFont(ofSize: 13).fontName))
        // Untouched: monospaced requests, small sizes.
        for f in [NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)] {
            #expect(f.fontName != regular && f.fontName != bold, "\(f)")
        }
        #expect(NSFont.systemFont(ofSize: 8).fontName != regular, "under 9 pt")
        // Dark appearance and the kill switch give the system font back.
        W7FontSubstitutionUseLightOverride(0)
        #expect(NSFont.systemFont(ofSize: 13).fontName == systemName)
        W7FontSubstitutionUseLightOverride(1)
        W7FontSubstitutionUseDisabledOverride(1)
        #expect(NSFont.systemFont(ofSize: 13).fontName == systemName)
        W7FontSubstitutionUseDisabledOverride(0)
        #expect(NSFont.systemFont(ofSize: 13).fontName == regular)
        W7FontSubstitutionDeactivate()
        #expect(NSFont.systemFont(ofSize: 13).fontName == systemName)
    }
}
