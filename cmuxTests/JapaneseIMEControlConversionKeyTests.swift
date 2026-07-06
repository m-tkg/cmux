import AppKit
import Carbon.HIToolbox
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Japanese IME conversion keys (Ctrl+J = hiragana, Ctrl+K = katakana) pressed
/// while composing must stay with the input method. They must never leak into
/// the terminal as raw control codes (^J executes the shell line, ^K kills to
/// end of line), and preedit text the IME commits in response to such a key
/// must reach the terminal as plain text without the control key encoding.
@MainActor
@Suite(.serialized)
struct JapaneseIMEControlConversionKeyTests {
    private static let japaneseInputSourceId = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"

    private struct HostedTerminalWindow {
        let surface: TerminalSurface
        let window: NSWindow
        let surfaceView: GhosttyNSView
    }

    private struct ForwardedPress {
        let keycode: UInt32
        let modsRawValue: UInt32
        let text: String?
    }

    private func makeHostedTerminalWindow() async throws -> HostedTerminalWindow {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        // Surface startup hops through main-queue jobs. A synchronous test body
        // would occupy the MainActor and starve them, so suspend (not spin the
        // run loop) until the Ghostty surface is live and keyDown can reach the
        // real forwarding paths.
        var attempts = 0
        while !surface.hasLiveSurface && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        try #require(
            surface.hasLiveSurface,
            "Ghostty surface must become live for keyDown forwarding tests"
        )

        return HostedTerminalWindow(
            surface: surface,
            window: window,
            surfaceView: try #require(findGhosttyNSView(in: hostedView))
        )
    }

    private func controlKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: Int,
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    private func setJapanesePreedit(_ text: String, on view: GhosttyNSView) {
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @Test
    func suppressesControlConversionKeyWhenIMEKeepsMarkedTextUnchanged() throws {
        let view = GhosttyNSView(frame: .zero)
        let probes: [(characters: String, ignoring: String, keyCode: Int)] = [
            ("\n", "j", kVK_ANSI_J),
            ("\u{0B}", "k", kVK_ANSI_K),
        ]

        for probe in probes {
            let event = try controlKeyEvent(
                characters: probe.characters,
                charactersIgnoringModifiers: probe.ignoring,
                keyCode: probe.keyCode
            )
            #expect(
                view.shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
                    markedTextBefore: "あいうえお",
                    markedSelectionBefore: NSRange(location: 5, length: 0),
                    markedTextAfter: "あいうえお",
                    markedSelectionAfter: NSRange(location: 5, length: 0),
                    accumulatedText: [],
                    event: event,
                    inputSourceId: Self.japaneseInputSourceId
                ),
                "Ctrl+\(probe.ignoring.uppercased()) during Japanese composition belongs to the IME and must not be forwarded to the terminal"
            )
        }
    }

    @Test
    func committedPreeditFromControlConversionKeyIsSentAsTextWithoutControlEncoding() async throws {
        let hostedTerminal = try await makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = Self.japaneseInputSourceId
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            // Simulate the input method committing the pending preedit because
            // it did not consume the control key itself (TSM fixes the
            // composition and delivers the text through insertText).
            candidateView.insertText(
                "あいうえお",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var presses: [ForwardedPress] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            presses.append(ForwardedPress(
                keycode: keyEvent.keycode,
                modsRawValue: keyEvent.mods.rawValue,
                text: keyEvent.text.map { String(cString: $0) }
            ))
        }

        setJapanesePreedit("あいうえお", on: surfaceView)
        #expect(surfaceView.hasMarkedText())

        let event = try controlKeyEvent(
            characters: "\n",
            charactersIgnoringModifiers: "j",
            keyCode: kVK_ANSI_J,
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        #expect(
            presses.map(\.text) == ["あいうえお"],
            "Committed preedit must reach the terminal exactly once as plain text"
        )
        for press in presses {
            #expect(
                press.modsRawValue & GHOSTTY_MODS_CTRL.rawValue == 0,
                "Committed preedit text must not carry the Control modifier (it would be encoded as ^J and execute in the shell)"
            )
            #expect(
                press.keycode != UInt32(kVK_ANSI_J),
                "Committed preedit text must not replay the original J keycode"
            )
        }
    }

    @Test
    func dropsAccumulatedBareControlCharacterWhileComposing() async throws {
        let hostedTerminal = try await makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        let previousInterpretHook = cjkIMEInterpretKeyEventsHook
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            cjkIMEInterpretKeyEventsHook = previousInterpretHook
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = Self.japaneseInputSourceId
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            // Simulate an IME flushing the raw control character through
            // insertText while a composition is active.
            candidateView.insertText(
                "\u{0B}",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        var forwardedPressCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            forwardedPressCount += 1
        }

        setJapanesePreedit("あ", on: surfaceView)
        #expect(surfaceView.hasMarkedText())

        let event = try controlKeyEvent(
            characters: "\u{0B}",
            charactersIgnoringModifiers: "k",
            keyCode: kVK_ANSI_K,
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        #expect(
            forwardedPressCount == 0,
            "A bare control character accumulated while composing belongs to the IME and must not reach the terminal"
        )
    }

    @Test
    func nonComposingControlJStillReachesTerminal() async throws {
        let hostedTerminal = try await makeHostedTerminalWindow()
        let terminalSurface = hostedTerminal.surface
        let window = hostedTerminal.window
        let surfaceView = hostedTerminal.surfaceView
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        let previousInputSourceOverride = KeyboardLayout.debugInputSourceIdOverride
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            KeyboardLayout.debugInputSourceIdOverride = previousInputSourceOverride
            window.orderOut(nil)
            withExtendedLifetime(terminalSurface) {}
        }

        KeyboardLayout.debugInputSourceIdOverride = Self.japaneseInputSourceId

        var forwardedControlPressKeyCodes: [UInt32] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS else { return }
            guard keyEvent.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 else { return }
            forwardedControlPressKeyCodes.append(keyEvent.keycode)
        }

        let event = try controlKeyEvent(
            characters: "\n",
            charactersIgnoringModifiers: "j",
            keyCode: kVK_ANSI_J,
            windowNumber: window.windowNumber
        )

        window.makeFirstResponder(surfaceView)
        withExtendedLifetime(terminalSurface) {
            surfaceView.keyDown(with: event)
        }

        #expect(
            forwardedControlPressKeyCodes == [UInt32(kVK_ANSI_J)],
            "Ctrl+J outside composition is normal terminal input and must keep reaching the terminal"
        )
    }
}
