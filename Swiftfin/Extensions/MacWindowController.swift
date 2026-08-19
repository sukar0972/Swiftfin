//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import UIKit

extension Notification.Name {
    static let swiftfinMacDidEnterFullScreen = Notification.Name("SwiftfinMacDidEnterFullScreen")
    static let swiftfinMacDidExitFullScreen = Notification.Name("SwiftfinMacDidExitFullScreen")
}

/// Controls the native macOS window that hosts the Catalyst scene.
@MainActor
final class MacWindowController {

    static let shared = MacWindowController()

    private static let windowFrameAutosaveName = "SwiftfinMacMainWindow"

    private enum Transition {
        case entering
        case exiting
        case idle
    }

    private var isPlayerCursorHidden = false
    private var isPointerInsidePlayer = false
    private var isWindowMain = true
    private var hasStartedObserving = false
    private var consumesNextEscape = false
    private var playerSessionID: UUID?
    private var playerWantsCursorHidden = false
    private var playbackActivity: NSObjectProtocol?
    private var playerHiddenTabBars: [UITabBar] = []
    private var observers: [NSObjectProtocol] = []
    private weak var trackedWindow: NSObject?
    private var transition: Transition = .idle

    private(set) var isFullScreen = false

    private init() {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return }

        observe("NSWindowDidEnterFullScreenNotification") { controller in
            controller.isFullScreen = true
            controller.transition = .idle
            controller.consumesNextEscape = true
            NotificationCenter.default.post(name: .swiftfinMacDidEnterFullScreen, object: nil)
            controller.configureWindowAppearanceAndRestoration(restoreFrame: false)
            // Catalyst may rebuild its tab bar while moving into the new Space.
            if controller.playerSessionID != nil {
                controller.hideTabBarForPlayer()
                controller.setHostToolbarHidden(true)
            }
        }
        observe("NSWindowWillExitFullScreenNotification") { controller in
            controller.transition = .exiting
        }
        observe("NSWindowDidExitFullScreenNotification") { controller in
            controller.isFullScreen = false
            controller.transition = .idle
            NotificationCenter.default.post(name: .swiftfinMacDidExitFullScreen, object: nil)
            controller.configureWindowAppearanceAndRestoration(restoreFrame: false)
            if controller.playerSessionID != nil {
                controller.hideTabBarForPlayer()
                controller.setHostToolbarHidden(true)
            }
        }
        observe("NSWindowDidFailToEnterFullScreenNotification") { controller in
            controller.transition = .idle
        }
        observe("NSWindowDidFailToExitFullScreenNotification") { controller in
            controller.transition = .idle
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
        configureCatalystTitlebar()
        guard let window = activeHostWindow() else { return false }

        // The Catalyst titlebar API removes its toolbar and separator. AppKit's
        // full-size content mask then extends UIKit beneath the remaining
        // transparent traffic-light region.
        if let styleMask = window.value(forKey: "styleMask") as? NSNumber {
            window.setValue(NSNumber(value: styleMask.uintValue | (1 << 15)), forKey: "styleMask")
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

        // Playback stays in the current window state. Native macOS full screen
        // is entered only when the user explicitly requests it.
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
        synchronizeWithWindow()
        guard UIDevice.isMac else { return false }

        // Consume Escape for the duration of either native transition. This
        // prevents the same key press from falling through to player dismissal
        // while AppKit is moving the Catalyst window between Spaces.
        guard transition == .idle else { return true }
        guard isFullScreen else { return false }

        if sendFullScreenAction() {
            transition = .exiting
            consumesNextEscape = false
        }
        return true
    }

    /// Returns whether Escape belongs to AppKit's native fullscreen exit.
    /// This never sends a fullscreen action: AppKit processes Escape before
    /// Catalyst delivers the corresponding UIKeyCommand.
    func consumeNativeFullScreenEscape() -> Bool {
        synchronizeWithWindow()
        guard UIDevice.isMac else { return false }

        guard consumesNextEscape || isFullScreen || transition == .exiting else { return false }
        consumesNextEscape = false
        return true
    }

    func toggleFullScreen() {
        synchronizeWithWindow()
        guard UIDevice.isMac, transition == .idle else { return }
        if isFullScreen {
            exitFullScreen()
        } else if sendFullScreenAction() {
            transition = .entering
            consumesNextEscape = true
        }
    }

    func endPlayerSession(_ sessionID: UUID?) {
        guard playerSessionID == sessionID else { return }
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

    private func hostWindow() -> NSObject? {
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = applicationClass
                  .perform(NSSelectorFromString("sharedApplication"))?
                  .takeUnretainedValue() as? NSObject
        else { return nil }

        return application.value(forKey: "keyWindow") as? NSObject
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
            isFullScreen = (styleMask.uintValue & (1 << 14)) != 0

            // Fullscreen notifications can be skipped while Catalyst replaces
            // or reparents its host window. Treat the live AppKit style mask as
            // completion of the pending transition so the next user action is
            // never ignored by a stale transition guard.
            switch transition {
            case .entering where isFullScreen,
                 .exiting where !isFullScreen:
                transition = .idle
            default:
                break
            }
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
