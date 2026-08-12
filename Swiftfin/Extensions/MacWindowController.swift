//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import UIKit

/// Controls the native macOS window that hosts the Catalyst scene.
@MainActor
final class MacWindowController {

    static let shared = MacWindowController()

    private enum Transition {
        case entering
        case exiting
        case idle
    }

    private var enteredFullScreenForPlayer = false
    private var playerHostToolbar: NSObject?
    private var playerHiddenTabBars: [UITabBar] = []
    private var observers: [NSObjectProtocol] = []
    private var restoreAfterTransition = false
    private var transition: Transition = .idle

    private(set) var isFullScreen = false

    private init() {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return }

        observe("NSWindowDidEnterFullScreenNotification") { controller in
            controller.isFullScreen = true
            controller.transition = .idle
            // Catalyst may rebuild its tab bar while moving into the new Space.
            controller.hideTabBarForPlayer()
            controller.setHostToolbarHidden(true)
            if controller.restoreAfterTransition {
                controller.restoreAfterTransition = false
                controller.enteredFullScreenForPlayer = false
                controller.exitFullScreen()
            }
        }
        observe("NSWindowDidExitFullScreenNotification") { controller in
            controller.isFullScreen = false
            controller.transition = .idle
        }
        observe("NSWindowDidFailToEnterFullScreenNotification") { controller in
            controller.enteredFullScreenForPlayer = false
            controller.restoreAfterTransition = false
            controller.transition = .idle
        }
        observe("NSWindowDidFailToExitFullScreenNotification") { controller in
            controller.transition = .idle
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
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                handler(self)
            }
        }
        observers.append(observer)
    }

    /// Forces observer registration when the first Catalyst scene appears.
    func startObserving() {}

    @discardableResult
    private func sendFullScreenAction() -> Bool {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return false }

        let selector = NSSelectorFromString("toggleFullScreen:")

        // Catalyst does not expose NSWindow at compile time, but the hosting
        // AppKit objects are available through the Objective-C runtime.
        if let window = hostWindow(),
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

    func enterPlayerFullScreen() {
        guard UIDevice.isMac else { return }
        hideTabBarForPlayer()
        setHostToolbarHidden(true)
        if transition == .entering, restoreAfterTransition {
            restoreAfterTransition = false
            enteredFullScreenForPlayer = true
            return
        }
        guard !isFullScreen, transition == .idle else { return }
        if sendFullScreenAction() {
            transition = .entering
            enteredFullScreenForPlayer = true
        }
    }

    func exitFullScreen() {
        guard UIDevice.isMac, isFullScreen, transition == .idle else { return }
        if sendFullScreenAction() {
            transition = .exiting
        }
    }

    func toggleFullScreen() {
        guard UIDevice.isMac, transition == .idle else { return }
        if isFullScreen {
            exitFullScreen()
        } else if sendFullScreenAction() {
            transition = .entering
            enteredFullScreenForPlayer = true
        }
    }

    func restoreWindowAfterPlayer() {
        playerHiddenTabBars.forEach { $0.isHidden = false }
        playerHiddenTabBars = []
        setHostToolbarHidden(false)

        guard enteredFullScreenForPlayer else { return }
        if transition == .entering {
            restoreAfterTransition = true
            return
        }
        if isFullScreen {
            exitFullScreen()
        }
        enteredFullScreenForPlayer = false
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

    private func setHostToolbarHidden(_ hidden: Bool) {
        if playerHostToolbar == nil {
            playerHostToolbar = hostWindow()?.value(forKey: "toolbar") as? NSObject
        }
        playerHostToolbar?.setValue(!hidden, forKey: "visible")
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
