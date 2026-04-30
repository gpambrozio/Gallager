import Testing
@testable import ClaudeSpyE2ELib

@Suite("TestStep failureScope")
struct TestStepScopeTests {
    @Test("iOS steps map to .ios scope")
    func iosSteps() {
        #expect(TestStep.launchIOSApp().failureScope == .ios)
        #expect(TestStep.terminateIOSApp.failureScope == .ios)
        #expect(TestStep.iosTap(.label("foo")).failureScope == .ios)
        #expect(TestStep.iosWaitForElement(.label("foo")).failureScope == .ios)
        #expect(TestStep.iosScreenshot(label: "x").failureScope == .ios)
        #expect(TestStep.iosLogUI.failureScope == .ios)
    }

    @Test("macOS steps default to instance 0 scope")
    func macStepsDefaultInstance() {
        #expect(TestStep.launchMacApp().failureScope == .macOS(instance: 0))
        #expect(TestStep.terminateMacApp().failureScope == .macOS(instance: 0))
        #expect(TestStep.macClickButton(titled: "OK").failureScope == .macOS(instance: 0))
        #expect(TestStep.macWaitForWindow(titled: "Settings").failureScope == .macOS(instance: 0))
        #expect(TestStep.macScreenshot(label: "x").failureScope == .macOS(instance: 0))
    }

    @Test("macOS steps preserve explicit instance")
    func macStepsExplicitInstance() {
        #expect(TestStep.launchMacApp(instance: 1).failureScope == .macOS(instance: 1))
        #expect(TestStep.macClickButton(titled: "OK", instance: 2).failureScope == .macOS(instance: 2))
        #expect(TestStep.macReadClipboard(storeAs: "k", instance: 3).failureScope == .macOS(instance: 3))
        #expect(TestStep.macSendHookEvent(json: "{}", tmuxPane: "x", instance: 4).failureScope == .macOS(instance: 4))
    }

    @Test("Server steps map to .universal scope")
    func serverSteps() {
        #expect(TestStep.startServer.failureScope == .universal)
        #expect(TestStep.verifyServerHealth.failureScope == .universal)
        #expect(TestStep.waitForHostConnected().failureScope == .universal)
        #expect(TestStep.stopServer.failureScope == .universal)
    }

    @Test("Tmux, assertions, and general steps map to .universal scope")
    func universalSteps() {
        #expect(TestStep.tmuxCreateSession(name: "s", width: 80, height: 24).failureScope == .universal)
        #expect(TestStep.tmuxSendKeys(target: "x", keys: "y").failureScope == .universal)
        #expect(TestStep.assertStoredEqual(key: "a", otherKey: "b").failureScope == .universal)
        #expect(TestStep.assertStoredContains(key: "a", substring: "x").failureScope == .universal)
        #expect(TestStep.wait(seconds: 1).failureScope == .universal)
        #expect(TestStep.storeValue(key: "k", value: "v").failureScope == .universal)
        #expect(TestStep.log("hi").failureScope == .universal)
    }
}
