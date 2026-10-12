//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import Combine
import UIKit

extension Notification.Name {
    static let swiftfinMacWillEnterFullScreen = Notification.Name("SwiftfinMacWillEnterFullScreen")
    static let swiftfinMacDidEnterFullScreen = Notification.Name("SwiftfinMacDidEnterFullScreen")
    static let swiftfinMacDidExitFullScreen = Notification.Name("SwiftfinMacDidExitFullScreen")
}

/// Controls the native macOS window that hosts the Catalyst scene.
@MainActor
final class MacWindowController: ObservableObject {

    static let shared = MacWindowController()

    private static let windowFrameAutosaveName = "SwiftfinMacMainWindow"

    private var isPlayerCursorHidden = false
    private var isPointerInsidePlayer = false
    private var isWindowMain = true
    private var hasStartedObserving = false
    private var lastNativeFullScreenExitTime: TimeInterval?
    private let playerFullScreen = MacPlayerFullScreen()
    private var playerSessionID: UUID?
    private var playerWantsCursorHidden = false
    private var playbackActivity: NSObjectProtocol?
    private var playerHiddenTabBars: [UITabBar] = []
    private var observers: [NSObjectProtocol] = []
    private weak var trackedWindow: NSObject?

    @Published
    private(set) var isFullScreen = false
    @Published
    private(set) var isPlayerFullScreen = false

    private init() {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return }

        observe("NSWindowWillEnterFullScreenNotification") { controller in
            controller.playerFullScreen.nativeWillEnter()
            NotificationCenter.default.post(name: .swiftfinMacWillEnterFullScreen, object: nil)
        }
        observe("NSWindowDidEnterFullScreenNotification") { controller in
            controller.isFullScreen = true
            NotificationCenter.default.post(name: .swiftfinMacDidEnterFullScreen, object: nil)
            let shouldExit = controller.playerFullScreen.nativeDidEnter()
            controller.isPlayerFullScreen = controller.playerFullScreen.isActive
            controller.configureWindowAppearanceAndRestoration(restoreFrame: false)
            // Catalyst may rebuild its tab bar while moving into the new Space.
            if controller.playerSessionID != nil {
                controller.hideTabBarForPlayer()
                controller.setHostToolbarHidden(true)
            }
            if shouldExit {
                controller.exitPlayerFullScreen()
            }
        }
        observe("NSWindowWillExitFullScreenNotification") { controller in
            controller.playerFullScreen.nativeWillExit()
        }
        observe("NSWindowDidExitFullScreenNotification") { controller in
            controller.isFullScreen = false
            controller.playerFullScreen.nativeDidExit()
            controller.isPlayerFullScreen = false
            controller.lastNativeFullScreenExitTime = ProcessInfo.processInfo.systemUptime
            NotificationCenter.default.post(name: .swiftfinMacDidExitFullScreen, object: nil)
            controller.configureWindowAppearanceAndRestoration(restoreFrame: false)
            if controller.playerSessionID != nil {
                controller.hideTabBarForPlayer()
                controller.setHostToolbarHidden(true)
            }
        }
        observe("NSWindowDidFailToEnterFullScreenNotification") { controller in
            controller.playerFullScreen.nativeDidExit()
            controller.isPlayerFullScreen = false
            NotificationCenter.default.post(name: .swiftfinMacDidExitFullScreen, object: nil)
        }
        observe("NSWindowDidFailToExitFullScreenNotification") { controller in
            controller.playerFullScreen.nativeDidFailToExit()
        }
        observe("NSWindowDidBecomeMainNotification") { controller in
            controller.isWindowMain = true
            controller.configureWindowAppearanceAndRestoration(restoreFrame: false)
            controller.updatePlayerCursorVisibility()
        }
        observe("NSWindowDidResignMainNotification") { controller in
            controller.isWindowMain = false
            controller.updatePlayerCursorVisibility()
        }
    }

    private func observe(
        _ name: String,
        handler: @escaping @MainActor (MacWindowController) -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let notificationWindow = notification.object as? NSObject else { return }
                // Catalyst can replace the AppKit host during a fullscreen
                // transition, so its fullscreen lifecycle notification is the
                // authoritative handoff. Ordinary main-window notifications
                // must remain pinned to the host to avoid adopting dialogs.
                if name.contains("FullScreen") {
                    self.trackedWindow = notificationWindow
                } else if !self.isTrackedHostWindow(notificationWindow) {
                    return
                }
                handler(self)
            }
        }
        observers.append(observer)
    }

    /// Captures the scene's AppKit host window and synchronizes state when the
    /// first Catalyst scene appears.
    func startObserving() {
        guard !hasStartedObserving else { return }
        hasStartedObserving = true

        Task { @MainActor in
            // Catalyst installs its AppKit host asynchronously. Retry briefly
            // so appearance and frame restoration cannot be lost at launch.
            for _ in 0 ..< 20 {
                if configureWindowAppearanceAndRestoration(restoreFrame: true) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }

            synchronizeWithWindow()
        }
    }

    @discardableResult
    private func configureWindowAppearanceAndRestoration(restoreFrame: Bool) -> Bool {
        // AppKit owns chrome and geometry throughout a native Space transition.
        guard playerFullScreen.transition == .idle else { return true }
        configureCatalystTitlebar()
        guard let window = activeHostWindow() else { return false }

        // The Catalyst titlebar API removes its toolbar and separator. AppKit's
        // full-size content mask then extends UIKit beneath the remaining
        // transparent traffic-light region.
        if let styleMask = window.value(forKey: "styleMask") as? NSNumber {
            if styleMask.uintValue & (1 << 15) == 0 {
                window.setValue(NSNumber(value: styleMask.uintValue | (1 << 15)), forKey: "styleMask")
            }
        }
        window.setValue(true, forKey: "titlebarAppearsTransparent")
        window.setValue("", forKey: "title")

        if restoreFrame {
            let restoreSelector = NSSelectorFromString("setFrameUsingName:")
            if window.responds(to: restoreSelector) {
                window.perform(restoreSelector, with: Self.windowFrameAutosaveName)
            }
        }

        let selector = NSSelectorFromString("setFrameAutosaveName:")
        if window.responds(to: selector) {
            window.perform(selector, with: Self.windowFrameAutosaveName)
        }
        return true
    }

    private func configureCatalystTitlebar() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        // This is Catalyst's supported title-bar removal path. Merely hiding
        // the underlying NSToolbar leaves its layout region above UIKit,
        // which appears as a black strip over fullscreen video.
        windowScene.titlebar?.titleVisibility = .hidden
        windowScene.titlebar?.toolbar = nil
    }

    @discardableResult
    private func sendFullScreenAction() -> Bool {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return false }

        let selector = NSSelectorFromString("toggleFullScreen:")

        // Catalyst does not expose NSWindow at compile time, but the hosting
        // AppKit objects are available through the Objective-C runtime.
        if let window = activeHostWindow(),
           window.responds(to: selector)
        {
            window.perform(selector, with: nil)
            return true
        }

        // Fall back to the responder chain for older Catalyst runtimes.
        return UIApplication.shared.sendAction(
            selector,
            to: nil,
            from: nil,
            for: nil
        )
    }

    func beginPlayerSession() -> UUID? {
        guard UIDevice.isMac else { return nil }
        synchronizeWithWindow()
        hideTabBarForPlayer()
        setHostToolbarHidden(true)

        // Playback starts in the current window state. A player that starts in
        // an existing fullscreen Space must leave that Space intact on close.
        let sessionID = UUID()
        playerSessionID = sessionID
        isPointerInsidePlayer = false
        playerWantsCursorHidden = false
        updatePlayerCursorVisibility()
        return sessionID
    }

    func setPlayerCursorHidden(_ hidden: Bool, sessionID: UUID?) {
        guard playerSessionID == sessionID else { return }
        playerWantsCursorHidden = hidden
        updatePlayerCursorVisibility()
    }

    func setPointerInsidePlayer(_ inside: Bool, sessionID: UUID?) {
        guard let sessionID, playerSessionID == sessionID else { return }
        isPointerInsidePlayer = inside
        updatePlayerCursorVisibility()
    }

    private func updatePlayerCursorVisibility() {
        let shouldHide = playerSessionID != nil && playerWantsCursorHidden && isPointerInsidePlayer && isWindowMain
        guard shouldHide != isPlayerCursorHidden,
              let cursorClass = NSClassFromString("NSCursor") as? NSObject.Type
        else { return }

        let selector = NSSelectorFromString(shouldHide ? "hide" : "unhide")
        guard cursorClass.responds(to: selector) else { return }
        cursorClass.perform(selector)
        isPlayerCursorHidden = shouldHide
    }

    func setPlaybackActive(_ active: Bool, sessionID: UUID?) {
        guard UIDevice.isMac else { return }

        let shouldPreventSleep = active && sessionID != nil && playerSessionID == sessionID
        UIApplication.shared.isIdleTimerDisabled = shouldPreventSleep

        if shouldPreventSleep, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                reason: "Swiftfin video playback"
            )
        } else if !shouldPreventSleep, let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    @discardableResult
    func exitFullScreen() -> Bool {
        guard UIDevice.isMac else { return false }
        if exitPlayerFullScreen() {
            return true
        }
        synchronizeWithWindow()
        guard playerFullScreen.transition == .idle else { return true }
        guard isFullScreen else { return false }

        playerFullScreen.nativeWillExit()
        if !sendFullScreenAction() {
            playerFullScreen.nativeDidFailToExit()
        }
        return true
    }

    /// Escape first leaves player fullscreen. A native exit that AppKit has
    /// already started must not also dismiss playback on the same key press.
    func handlePlayerEscape() -> Bool {
        guard UIDevice.isMac else { return false }
        if exitPlayerFullScreen() {
            return true
        }
        guard playerFullScreen.transition == .idle else { return true }
        if let lastNativeFullScreenExitTime,
           ProcessInfo.processInfo.systemUptime - lastNativeFullScreenExitTime < 0.5
        {
            self.lastNativeFullScreenExitTime = nil
            return true
        }
        return false
    }

    func togglePlayerFullScreen() {
        synchronizeWithWindow()
        guard UIDevice.isMac, playerFullScreen.transition == .idle else { return }

        if exitPlayerFullScreen() {
            return
        }
        let reuseNativeFullScreen = isFullScreen
        if playerFullScreen.enter(isNativeFullScreen: reuseNativeFullScreen, toggle: sendFullScreenAction) {
            isPlayerFullScreen = true
            if reuseNativeFullScreen {
                NotificationCenter.default.post(name: .swiftfinMacWillEnterFullScreen, object: nil)
                NotificationCenter.default.post(name: .swiftfinMacDidEnterFullScreen, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: .swiftfinMacDidExitFullScreen, object: nil)
        }
    }

    @discardableResult
    private func exitPlayerFullScreen() -> Bool {
        guard playerFullScreen.exit(toggle: sendFullScreenAction) else { return false }
        isPlayerFullScreen = playerFullScreen.isActive
        synchronizeWithWindow()
        if playerFullScreen.transition == .idle {
            NotificationCenter.default.post(name: .swiftfinMacDidExitFullScreen, object: nil)
        }
        return true
    }

    func endPlayerSession(_ sessionID: UUID?) {
        guard let sessionID, playerSessionID == sessionID else { return }
        exitPlayerFullScreen()
        setPlaybackActive(false, sessionID: sessionID)
        playerWantsCursorHidden = false
        isPointerInsidePlayer = false
        updatePlayerCursorVisibility()
        playerSessionID = nil

        playerHiddenTabBars.forEach { $0.isHidden = false }
        playerHiddenTabBars = []
        setHostToolbarHidden(false)
    }

    private func hideTabBarForPlayer() {
        guard let rootView = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?
            .rootViewController?
            .view
        else { return }

        for tabBar in allTabBars(in: rootView) {
            if !playerHiddenTabBars.contains(where: { $0 === tabBar }) {
                playerHiddenTabBars.append(tabBar)
            }
            tabBar.isHidden = true
        }
    }

    private func hostApplication() -> NSObject? {
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = applicationClass
                  .perform(NSSelectorFromString("sharedApplication"))?
                  .takeUnretainedValue() as? NSObject
        else { return nil }

        return application
    }

    private func hostWindow() -> NSObject? {
        hostApplication()?.value(forKey: "keyWindow") as? NSObject
    }

    private func activeHostWindow() -> NSObject? {
        if let trackedWindow {
            return trackedWindow
        }
        trackedWindow = hostWindow()
        return trackedWindow
    }

    private func isTrackedHostWindow(_ window: NSObject) -> Bool {
        if let trackedWindow {
            return trackedWindow === window
        }

        guard hostWindow() === window else { return false }
        trackedWindow = window
        return true
    }

    private func synchronizeWithWindow() {
        guard let window = activeHostWindow() else { return }

        // NSWindowStyleMask.fullScreen is 1 << 14. Reading the host window is
        // more reliable than assuming every AppKit notification was observed,
        // especially while Catalyst moves the window into another Space.
        if let styleMask = window.value(forKey: "styleMask") as? NSNumber {
            let isNativeFullScreen = (styleMask.uintValue & (1 << 14)) != 0
            isFullScreen = isNativeFullScreen
            // The style bit can change before the Space animation completes.
            // Only lifecycle completion notifications release the input guard.
        }
    }

    private func setHostToolbarHidden(_ hidden: Bool) {
        let toolbar = activeHostWindow()?.value(forKey: "toolbar") as? NSObject
        toolbar?.setValue(!hidden, forKey: "visible")
    }

    private func allTabBars(in view: UIView) -> [UITabBar] {
        var result: [UITabBar] = []

        if let tabBar = view as? UITabBar {
            result.append(tabBar)
        }

        for subview in view.subviews {
            result.append(contentsOf: allTabBars(in: subview))
        }

        return result
    }
}
#endif
