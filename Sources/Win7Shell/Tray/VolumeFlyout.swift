import AppKit
import Win7Core
import Win7Theme

/// The Windows 7 volume flyout: "Speakers" on top, a vertical slider, a mute toggle with a speaker
/// icon and a "Mixer" link that opens Sound settings. A device without a settable volume shows the
/// slider disabled.
@MainActor
final class VolumeFlyout: NSView {
    static let size = NSSize(width: 84, height: 272)
    private let control: VolumeControl
    private let slider: VolumeSlider
    private let muteButton: MuteButton

    init(control: VolumeControl) {
        self.control = control
        slider = VolumeSlider(frame: NSRect(x: (VolumeFlyout.size.width - 30) / 2, y: 82, width: 30, height: 150))
        muteButton = MuteButton(frame: NSRect(x: (VolumeFlyout.size.width - 32) / 2, y: 40, width: 32, height: 32))
        super.init(frame: NSRect(origin: .zero, size: VolumeFlyout.size))

        let title = flyoutLabel("Speakers")
        title.setFrameOrigin(NSPoint(x: (bounds.width - title.frame.width) / 2, y: bounds.height - 26))
        addSubview(title)

        slider.onChange = { [weak control] v in control?.setVolume(v) }
        addSubview(slider)
        muteButton.onClick = { [weak control] in control?.toggleMute() }
        addSubview(muteButton)

        let mixer = FlyoutLink("Mixer") {
            openSettings(.sound)
        }
        mixer.setFrameOrigin(NSPoint(x: (bounds.width - mixer.frame.width) / 2, y: 10))
        addSubview(mixer)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Mirrors the control's current state (called when CoreAudio reports a change).
    func sync() {
        slider.value = control.volume
        slider.isEnabled = control.canSetVolume
        muteButton.level = control.level
        muteButton.isEnabled = control.canMute
    }

    override func scrollWheel(with event: NSEvent) { slider.scrollWheel(with: event) }
}

/// A Windows 7 vertical slider: a sunken track with a blue fill below a glossy thumb.
@MainActor
private final class VolumeSlider: NSView {
    var value: Float = 0 { didSet { if !dragging { needsDisplay = true } } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onChange: ((Float) -> Void)?
    private var dragging = false
    private var shown: Float = 0
    private var scrollAccumulator: CGFloat = 0
    private let thumbHeight: CGFloat = 10

    private var track: NSRect { NSRect(x: bounds.midX - 2, y: thumbHeight / 2, width: 4, height: bounds.height - thumbHeight) }

    override func draw(_ dirtyRect: NSRect) {
        if !dragging { shown = value }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let t = track
        let groove = NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0xE7 / 255.0, green: 0xEA / 255.0, blue: 0xEA / 255.0, alpha: 1).setFill()
        groove.fill()
        NSColor(srgbRed: 0xB0 / 255.0, green: 0xB4 / 255.0, blue: 0xBA / 255.0, alpha: 1).setStroke()
        groove.stroke()
        let y = t.minY + t.height * CGFloat(shown)
        let filled = NSRect(x: t.minX + 1, y: t.minY + 1, width: t.width - 2, height: max(0, y - t.minY - 1))
        NSColor(srgbRed: 0x3C / 255.0, green: 0x8F / 255.0, blue: 0xE0 / 255.0, alpha: 1).setFill()
        filled.fill()
        // Thumb: a rounded tab, glossy blue-grey like the Windows 7 trackbar.
        let thumb = NSRect(x: bounds.midX - 11, y: y - thumbHeight / 2, width: 22, height: thumbHeight)
        let tp = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(srgbRed: 0xFB / 255.0, green: 0xFC / 255.0, blue: 0xFD / 255.0, alpha: 1),
                   ending: NSColor(srgbRed: 0xC9 / 255.0, green: 0xD6 / 255.0, blue: 0xE5 / 255.0, alpha: 1))?
            .draw(in: tp, angle: -90)
        NSColor(srgbRed: 0x6F / 255.0, green: 0x86 / 255.0, blue: 0xA0 / 255.0, alpha: 1).setStroke()
        tp.lineWidth = 1
        tp.stroke()
    }

    private func value(at p: NSPoint) -> Float {
        let t = track
        return Float(max(0, min(1, (p.y - t.minY) / t.height)))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragging = true
        apply(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, dragging else { return }
        apply(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    private func apply(_ v: Float) {
        shown = v
        needsDisplay = true
        onChange?(v)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        let notches = TrayScroll.notches(event, accumulator: &scrollAccumulator)
        guard notches != 0 else { return }
        apply(max(0, min(1, value + Float(notches) * 0.05)))
    }
}

/// The mute toggle: a speaker icon button, with the red muted mark when muted.
@MainActor
private final class MuteButton: NSView {
    var level: VolumeLevel = .high { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAlpha(isEnabled ? 1 : 0.4)
        if hover && isEnabled {
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor(srgbRed: 0xE5 / 255.0, green: 0xF3 / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
            r.fill()
            NSColor(srgbRed: 0x7D / 255.0, green: 0xA2 / 255.0, blue: 0xCE / 255.0, alpha: 1).setStroke()
            r.stroke()
        }
        let side: CGFloat = 24
        TrayIcons.draw(ctx, in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                       kind: .volume, level: level.iconLevel, flag: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Turns scroll events into whole notches (positive = up = louder, whatever the natural-scrolling
/// setting): wheel lines map 1:1, trackpad deltas accumulate.
enum TrayScroll {
    static let pointsPerNotch: CGFloat = 12

    static func notches(_ event: NSEvent, accumulator: inout CGFloat) -> Int {
        let d = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            return d == 0 ? 0 : (d > 0 ? max(1, Int(d.rounded())) : min(-1, Int(d.rounded())))
        }
        accumulator += d
        let n = Int(accumulator / pointsPerNotch)
        accumulator -= CGFloat(n) * pointsPerNotch
        return n
    }
}
