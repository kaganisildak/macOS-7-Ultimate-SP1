import Testing
import Win7Core
import Win7Theme

/// Win7Core cannot import Win7Theme; this product links both, so it pins constants the shell duplicates.
@Suite struct ConstantPinTests {
    /// The shell recognizes the dylib's frame overlays by their geometry.
    @Test func shellFrameBorderWidthMatchesTheTheme() {
        #expect(WindowList.frameBorderWidth == W7FrameBorderWidth)
    }
}
