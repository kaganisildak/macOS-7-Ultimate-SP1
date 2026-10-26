import CoreGraphics
import Testing
@testable import Win7Core

// the shell's dialogs (ShellDialog: device Properties, Screen Resolution's "Keep changes?") — the button row,
// the message box body and the placement over the parent inside the work area. AppKit coordinates (bottom-left).

@Suite struct ShellDialogLayoutTests {
    let workArea = CGRect(x: 0, y: 40, width: 1440, height: 835)   // a 40 pt taskbar along the bottom

    @Test func buttonsAreAtLeast75WideAndGrowWithTheirTitle() {
        #expect(ShellDialogLayout.buttonWidth(titleWidth: 30) == 75)
        #expect(ShellDialogLayout.buttonWidth(titleWidth: 80.3) == 101)
        #expect(ShellDialogLayout.buttonHeight == 23)
    }

    @Test func aFaceDialogKeepsItsContentAndRightAlignsItsButtons() {
        // The device Properties dialog: 380 × 356 of content over a 44 pt button row on the same grey face.
        let f = ShellDialogLayout.layout(content: CGSize(width: 380, height: 356), buttonWidths: [75, 75], style: .face)
        #expect(f.size == CGSize(width: 380, height: 400))
        #expect(f.content == CGRect(x: 0, y: 44, width: 380, height: 356))
        #expect(f.strip == CGRect(x: 0, y: 0, width: 380, height: 44))
        #expect(f.buttons == [CGRect(x: 216, y: 11, width: 75, height: 23), CGRect(x: 297, y: 11, width: 75, height: 23)])
    }

    @Test func aMessageBoxHasItsButtonStripAndWidensForItsButtons() {
        let f = ShellDialogLayout.layout(content: CGSize(width: 300, height: 80), buttonWidths: [101, 75], style: .messageBox)
        #expect(f.size == CGSize(width: 300, height: 121))
        #expect(f.strip == CGRect(x: 0, y: 0, width: 300, height: 41))
        #expect(f.content == CGRect(x: 0, y: 41, width: 300, height: 80))
        #expect(f.buttons == [CGRect(x: 107, y: 9, width: 101, height: 23), CGRect(x: 214, y: 9, width: 75, height: 23)])
        // Buttons wider than the content widen the dialog; the content keeps its height and spans the width.
        let wide = ShellDialogLayout.layout(content: CGSize(width: 100, height: 50), buttonWidths: [75, 75, 75], style: .face)
        #expect(wide.size == CGSize(width: 253, height: 94))
        #expect(wide.content == CGRect(x: 0, y: 44, width: 253, height: 50))
        #expect(wide.buttons.first?.minX == 8 && wide.buttons.last?.maxX == 245)
        // No buttons: just the content and the strip.
        let none = ShellDialogLayout.layout(content: CGSize(width: 200, height: 60), buttonWidths: [], style: .messageBox)
        #expect(none.buttons.isEmpty && none.size == CGSize(width: 200, height: 101))
    }

    @Test func theMessageBodyPlacesTheIconAndTheWrappedText() {
        let m = ShellDialogLayout.message(textSize: CGSize(width: 250, height: 30), hasIcon: true)
        #expect(m.size == CGSize(width: 322, height: 64))
        #expect(m.icon == CGRect(x: 14, y: 16, width: 32, height: 32))
        #expect(m.text == CGRect(x: 58, y: 18, width: 250, height: 30))
        // Without an icon, text wider than the wrap width is held to it (the caller wraps at messageTextWidth).
        let plain = ShellDialogLayout.message(textSize: CGSize(width: 400, height: 60), hasIcon: false)
        #expect(ShellDialogLayout.messageTextWidth == 320)
        #expect(plain.icon == nil)
        #expect(plain.size == CGSize(width: 348, height: 92))
        #expect(plain.text == CGRect(x: 14, y: 16, width: 320, height: 60))
    }

    /// Review of a message changed while the dialog is open ("Reverting to previous display settings in N
    /// seconds.") is laid out again; the dialog grows to fit a longer text, never shrinks while open (so a countdown
    /// doesn't make it jitter), and the text and icon stay top-aligned in the grown body.
    @Test func aChangedMessageIsLaidOutAgainAndOnlyGrows() {
        let opened = ShellDialogLayout.message(textSize: CGSize(width: 250, height: 30), hasIcon: false)
        let first = ShellDialogLayout.layout(content: opened.size, buttonWidths: [101, 75], style: .messageBox)
        // Longer and taller text: the dialog grows to the new layout.
        let longer = ShellDialogLayout.relayout(textSize: CGSize(width: 300, height: 45), hasIcon: false, buttonWidths: [101, 75],
                                                current: first)
        let expectedMessage = ShellDialogLayout.message(textSize: CGSize(width: 300, height: 45), hasIcon: false)
        #expect(longer.message == expectedMessage)
        #expect(longer.frames == ShellDialogLayout.layout(content: expectedMessage.size, buttonWidths: [101, 75], style: .messageBox))
        // Shorter text ("9 seconds" after "10 seconds"): the size stays, the text moves up to the top.
        let shorter = ShellDialogLayout.relayout(textSize: CGSize(width: 240, height: 15), hasIcon: true, buttonWidths: [101, 75],
                                                 current: longer.frames)
        #expect(shorter.frames.size == longer.frames.size)
        #expect(shorter.frames.content == longer.frames.content)
        let h = longer.frames.content.height
        #expect(shorter.message.size == CGSize(width: longer.frames.size.width, height: h))
        #expect(shorter.message.text == CGRect(x: 58, y: h - 16 - 15, width: 240, height: 15))
        #expect(shorter.message.icon == CGRect(x: 14, y: h - 16 - 32, width: 32, height: 32))
    }

    @Test func aDialogIsCentredOnItsParentInsideTheWorkArea() {
        let size = CGSize(width: 380, height: 400)
        #expect(ShellDialogLayout.origin(size: size, parent: CGRect(x: 100, y: 100, width: 520, height: 460), workArea: workArea)
                == CGPoint(x: 170, y: 130))
        // A small parent near the top right: the dialog stays wholly inside, its caption under the top edge.
        #expect(ShellDialogLayout.origin(size: size, parent: CGRect(x: 1300, y: 700, width: 200, height: 150), workArea: workArea)
                == CGPoint(x: 1060, y: 475))
        // A parent reaching under the taskbar and past the left edge: moved up and right.
        #expect(ShellDialogLayout.origin(size: size, parent: CGRect(x: 0, y: -200, width: 200, height: 100), workArea: workArea)
                == CGPoint(x: 0, y: 40))
        // Taller or wider than the work area: its caption and left edge stay on screen.
        #expect(ShellDialogLayout.origin(size: CGSize(width: 2000, height: 1000),
                                         parent: CGRect(x: 100, y: 100, width: 520, height: 460), workArea: workArea)
                == CGPoint(x: 0, y: -125))
        // No parent: centred in the work area, on whole points.
        #expect(ShellDialogLayout.origin(size: size, parent: nil, workArea: workArea) == CGPoint(x: 530, y: 257))
        // A display left of the primary (negative coordinates).
        let side = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        #expect(ShellDialogLayout.origin(size: size, parent: CGRect(x: -400, y: 900, width: 520, height: 460), workArea: side)
                == CGPoint(x: -380, y: 655))
    }
}
