import Foundation

/// The platform target a step exercises. On step failure, the orchestrator uses
/// this to decide which app to capture a diagnostic screenshot of.
///
/// - `.ios`: the step targets the iOS simulator
/// - `.macOS(instance:)`: the step targets a specific macOS app instance
/// - `.universal`: the step does not target a specific platform; capture
///   screenshots from every running platform (iOS sim + all macOS instances).
///   Used for assertions, server steps, tmux steps, and generic helpers
///   where the failure could affect any of the running components.
public enum TestStepScope: Sendable, Equatable {
    case ios
    case macOS(instance: Int)
    case universal
}

public extension TestStep {
    /// Platform scope for this step, used to decide which platforms to
    /// screenshot when the step fails (excluding screenshot-comparison
    /// failures, which already carry an actual/baseline/diff triplet).
    var failureScope: TestStepScope {
        switch self {
        // iOS simulator
        case .launchIOSApp,
             .terminateIOSApp,
             .uninstallIOSApp,
             .iosWaitForElement,
             .iosTap,
             .iosLongPress,
             .iosTapCoordinate,
             .iosType,
             .iosSwipeLeft,
             .iosSwipe,
             .iosWaitForElementToDisappear,
             .iosScreenshot,
             .iosLogUI,
             .iosReadClipboard,
             .iosClearClipboard,
             .iosSetAppVersion:
            return .ios
        // macOS app (specific instance)
        case let .launchMacApp(instance, _, _):
            return .macOS(instance: instance)
        case let .terminateMacApp(instance):
            return .macOS(instance: instance)
        case let .macActivate(instance):
            return .macOS(instance: instance)
        case let .macDeactivate(instance):
            return .macOS(instance: instance)
        case let .macOpenSettings(instance):
            return .macOS(instance: instance)
        case let .macCloseWindow(_, instance):
            return .macOS(instance: instance)
        case let .macWaitForWindow(_, _, instance):
            return .macOS(instance: instance)
        case let .macAssertWindowTitle(_, _, instance):
            return .macOS(instance: instance)
        case let .macSelectSettingsTab(_, instance):
            return .macOS(instance: instance)
        case let .macClickButton(_, instance):
            return .macOS(instance: instance)
        case let .macClickMenuItem(_, _, instance):
            return .macOS(instance: instance)
        case let .macPressKey(_, _, instance):
            return .macOS(instance: instance)
        case let .macCGClick(_, instance):
            return .macOS(instance: instance)
        case let .macCGClickElement(_, _, instance, _):
            return .macOS(instance: instance)
        case let .macRightClick(_, instance):
            return .macOS(instance: instance)
        case let .macContextMenuClick(_, _, instance):
            return .macOS(instance: instance)
        case let .macContextSubmenuClick(_, _, _, instance):
            return .macOS(instance: instance)
        case let .macUnpair(instance):
            return .macOS(instance: instance)
        case let .macSetAppVersion(_, _, instance):
            return .macOS(instance: instance)
        case let .macReadClipboard(_, instance):
            return .macOS(instance: instance)
        case let .macWriteClipboard(_, instance):
            return .macOS(instance: instance)
        case let .macWriteClipboardImage(_, _, instance):
            return .macOS(instance: instance)
        case let .macReadClipboardImage(_, instance):
            return .macOS(instance: instance)
        case let .macClearClipboard(instance):
            return .macOS(instance: instance)
        case let .setGitMockChanges(_, instance):
            return .macOS(instance: instance)
        case let .macPaste(instance):
            return .macOS(instance: instance)
        case let .macDropFilesOnPane(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElement(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElementVisible(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElementNotVisible(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElementToDisappear(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElementQuery(_, _, instance):
            return .macOS(instance: instance)
        case let .macWaitForElementQueryToDisappear(_, _, instance):
            return .macOS(instance: instance)
        case let .macOpenPanesWindow(instance):
            return .macOS(instance: instance)
        case let .macMoveWindow(_, _, instance):
            return .macOS(instance: instance)
        case let .macResizeWindow(_, _, instance):
            return .macOS(instance: instance)
        case let .macSetSidebarWidth(_, instance):
            return .macOS(instance: instance)
        case let .macSetSidebarFields(_, instance):
            return .macOS(instance: instance)
        case let .macFocusElement(_, instance):
            return .macOS(instance: instance)
        case let .macType(_, _, _, instance):
            return .macOS(instance: instance)
        case let .macScrollUp(_, instance):
            return .macOS(instance: instance)
        case let .macScrollWheel(_, _, instance):
            return .macOS(instance: instance)
        case let .macScrollWheelAtElement(_, _, _, instance):
            return .macOS(instance: instance)
        case let .macClickAtPoint(_, _, instance):
            return .macOS(instance: instance)
        case let .macDrag(_, _, _, _, instance):
            return .macOS(instance: instance)
        case let .macDragElement(_, _, instance):
            return .macOS(instance: instance)
        case let .macScreenshot(_, _, _, _, instance):
            return .macOS(instance: instance)
        case let .macSendHookEvent(_, _, _, _, instance):
            return .macOS(instance: instance)
        case let .macStageSidecarFixture(_, instance, _):
            return .macOS(instance: instance)
        case let .macStageSidecarZip(_, _, _, instance):
            return .macOS(instance: instance)
        // Server, tmux, assertions, scripts, general — any running platform
        // could be relevant to diagnose the failure.
        case .startServer,
             .startStubLicenseServer,
             .startServerLicensed,
             .verifyServerHealth,
             .verifyServerHasPairings,
             .waitForHostConnected,
             .waitForViewerConnected,
             .serverDisconnectDevice,
             .serverBlockDevice,
             .serverUnblockDevice,
             .waitForNoPairings,
             .stopServer,
             .waitForAPNSPushCount,
             .verifyLastAPNSPush,
             .clearAPNSPushLog,
             .serverReadFirstViewerIdentity,
             .serverCompletePairingAsViewer,
             .serverInjectPush,
             .occupyTCPPort,
             .tmuxCreateSession,
             .tmuxStorePaneDimensions,
             .tmuxStorePaneId,
             .tmuxCapturePaneContent,
             .tmuxWaitForPaneContent,
             .tmuxSendKeys,
             .tmuxCommand,
             .tmuxStoreDisplayMessage,
             .waitForTmuxDisplayMessage,
             .waitForTmuxDisplayMessageNotEqual,
             .assertStoredEqual,
             .assertStoredNotEqual,
             .assertStoredContains,
             .assertStoredNotContains,
             .injectScript,
             .wait,
             .storeValue,
             .readFile,
             .removeFile,
             .writeFile,
             .waitForFileContains,
             .log:
            return .universal
        }
    }
}
