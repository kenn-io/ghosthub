import Testing
@testable import GhosthubTerminalSupport

@Suite("TerminalBackgroundAppearance")
struct TerminalBackgroundAppearanceTests {
    @Test("opaque by default")
    func opaqueDefault() {
        let appearance = TerminalBackgroundAppearance.opaque
        #expect(appearance.opacity == 1.0)
        #expect(appearance.blur == .disabled)
        #expect(!appearance.isTransparent)
    }

    @Test(
        "derives transparency from opacity",
        arguments: [
            (0.8, true),
            (1.0, false),
            (0.999, true),
        ]
    )
    func transparency(opacity: Double, transparent: Bool) {
        let appearance = TerminalBackgroundAppearance(
            opacity: opacity, blurCValue: 0, increasedContrast: false
        )
        #expect(appearance.isTransparent == transparent)
    }

    @Test("clamps out-of-range opacity")
    func clamping() {
        #expect(
            TerminalBackgroundAppearance(
                opacity: -0.5, blurCValue: 0, increasedContrast: false
            ).opacity == 0.0
        )
        #expect(
            TerminalBackgroundAppearance(
                opacity: 1.5, blurCValue: 0, increasedContrast: false
            ).opacity == 1.0
        )
    }

    @Test(
        "maps blur c-values",
        arguments: [
            (Int16(0), TerminalBackgroundBlur.disabled),
            (Int16(20), TerminalBackgroundBlur.radius(20)),
            (Int16(-1), TerminalBackgroundBlur.systemGlass),
            (Int16(-2), TerminalBackgroundBlur.systemGlass),
        ]
    )
    func blurMapping(cValue: Int16, expected: TerminalBackgroundBlur) {
        let appearance = TerminalBackgroundAppearance(
            opacity: 0.8, blurCValue: cValue, increasedContrast: false
        )
        #expect(appearance.blur == expected)
    }

    @Test("increased contrast forces opaque")
    func highContrast() {
        let appearance = TerminalBackgroundAppearance(
            opacity: 0.5, blurCValue: 20, increasedContrast: true
        )
        #expect(!appearance.isTransparent)
        #expect(appearance.opacity == 1.0)
        #expect(appearance.blur == .disabled)
    }

    @Test("window blur call is skipped only for glass styles")
    func blurCall() {
        #expect(
            TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: 20, increasedContrast: false
            ).appliesWindowBlur
        )
        // Radius 0 still calls through so a live-reload that disables
        // blur clears the window's existing blur radius.
        #expect(
            TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: 0, increasedContrast: false
            ).appliesWindowBlur
        )
        #expect(
            !TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: -1, increasedContrast: false
            ).appliesWindowBlur
        )
        // Opaque windows never apply blur.
        #expect(
            !TerminalBackgroundAppearance(
                opacity: 1.0, blurCValue: 20, increasedContrast: false
            ).appliesWindowBlur
        )
    }
}
