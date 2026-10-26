import CoreGraphics

/// The geometry of the shell's Windows 7 dialogs (ShellDialog in Win7Shell: the device Properties dialog
/// the "Keep changes?"). AppKit coordinates (bottom-left origin): the button row runs along the bottom, the
/// content sits above it.
public enum ShellDialogLayout {
    /// `.face`: one grey face, the buttons under the content (Properties sheets). `.messageBox`: a white body over
    /// a grey button strip with a line along its top (Windows 7 message boxes).
    public enum Style: Sendable { case face, messageBox }

    public struct Frames: Equatable, Sendable {
        /// The dialog's content size.
        public var size: CGSize
        /// The caller's content (a custom view, or the message body).
        public var content: CGRect
        /// The button row along the bottom.
        public var strip: CGRect
        /// The buttons, in the order given (left to right).
        public var buttons: [CGRect]
    }

    public struct MessageFrames: Equatable, Sendable {
        public var size: CGSize
        public var icon: CGRect?
        public var text: CGRect
    }

    public static let buttonHeight: CGFloat = 23
    public static let minimumButtonWidth: CGFloat = 75
    /// Space on each side of a button's title.
    public static let buttonTitlePadding: CGFloat = 10
    public static let buttonGap: CGFloat = 6
    /// The message box text wraps at this width.
    public static let messageTextWidth: CGFloat = 320
    static let messageMargin: CGFloat = 14
    static let messageVertical: CGFloat = 16
    static let iconSide: CGFloat = 32
    static let iconTextGap: CGFloat = 12

    static func stripHeight(_ style: Style) -> CGFloat { style == .face ? 44 : 41 }
    static func buttonInset(_ style: Style) -> (right: CGFloat, bottom: CGFloat) { style == .face ? (8, 11) : (11, 9) }

    public static func buttonWidth(titleWidth: CGFloat) -> CGFloat {
        max(minimumButtonWidth, (titleWidth + 2 * buttonTitlePadding).rounded(.up))
    }

    /// The dialog for `content` and buttons of `buttonWidths`: as wide as the content or the button row with its
    /// margins, whichever is wider; the buttons right-aligned in the strip.
    public static func layout(content: CGSize, buttonWidths: [CGFloat], style: Style) -> Frames {
        let inset = buttonInset(style)
        let row = buttonWidths.reduce(0, +) + CGFloat(max(0, buttonWidths.count - 1)) * buttonGap
        let width = max(content.width, buttonWidths.isEmpty ? 0 : row + 2 * inset.right)
        let strip = stripHeight(style)
        var x = width - inset.right - row
        let buttons = buttonWidths.map { w -> CGRect in
            defer { x += w + buttonGap }
            return CGRect(x: x, y: inset.bottom, width: w, height: buttonHeight)
        }
        return Frames(size: CGSize(width: width, height: strip + content.height),
                      content: CGRect(x: 0, y: strip, width: width, height: content.height),
                      strip: CGRect(x: 0, y: 0, width: width, height: strip), buttons: buttons)
    }

    /// The message body for text measured at `textSize` (wrapped at `messageTextWidth`): the 32 pt icon at the
    /// top left, the text beside it, both top-aligned.
    public static func message(textSize: CGSize, hasIcon: Bool) -> MessageFrames {
        let textWidth = min(textSize.width.rounded(.up), messageTextWidth)
        let textHeight = textSize.height.rounded(.up)
        let textX = hasIcon ? messageMargin + iconSide + iconTextGap : messageMargin
        let height = messageVertical * 2 + max(hasIcon ? iconSide : 0, textHeight)
        let icon = hasIcon ? CGRect(x: messageMargin, y: height - messageVertical - iconSide, width: iconSide, height: iconSide) : nil
        return MessageFrames(size: CGSize(width: textX + textWidth + messageMargin, height: height), icon: icon,
                             text: CGRect(x: textX, y: height - messageVertical - textHeight, width: textWidth, height: textHeight))
    }

    /// A message box's new layout after its message changed while open (text measured at `textSize`): the dialog
    /// grows to fit (`message` then `layout`), never shrinks below `current` (a countdown would make it jitter),
    /// and the icon and text stay top-aligned in the body. The message frames' size is the body's.
    public static func relayout(textSize: CGSize, hasIcon: Bool, buttonWidths: [CGFloat],
                                current: Frames) -> (frames: Frames, message: MessageFrames) {
        var m = message(textSize: textSize, hasIcon: hasIcon)
        let content = CGSize(width: max(m.size.width, current.content.width), height: max(m.size.height, current.content.height))
        let frames = layout(content: content, buttonWidths: buttonWidths, style: .messageBox)
        let rise = frames.content.height - m.size.height
        m.icon = m.icon?.offsetBy(dx: 0, dy: rise)
        m.text = m.text.offsetBy(dx: 0, dy: rise)
        m.size = frames.content.size
        return (frames, m)
    }

    /// The dialog's frame origin: centred on `parent` (or in the work area without one), then moved wholly inside
    /// `workArea`; larger than the area, its caption and left edge stay on screen. Whole points.
    public static func origin(size: CGSize, parent: CGRect?, workArea: CGRect) -> CGPoint {
        let centre = parent.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: workArea.midX, y: workArea.midY)
        var x = centre.x - size.width / 2, y = centre.y - size.height / 2
        x = size.width > workArea.width ? workArea.minX : min(max(x, workArea.minX), workArea.maxX - size.width)
        y = size.height > workArea.height ? workArea.maxY - size.height : min(max(y, workArea.minY), workArea.maxY - size.height)
        return CGPoint(x: x.rounded(.down), y: y.rounded(.down))
    }
}
