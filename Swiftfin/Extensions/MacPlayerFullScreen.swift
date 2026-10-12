//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import Foundation

/// Owns player-initiated native fullscreen without disturbing an existing app Space.
/// Window notifications complete transitions; a style-mask change alone does not.
@MainActor
final class MacPlayerFullScreen {

    enum Transition {
        case idle
        case entering
        case exiting
    }

    private(set) var transition: Transition = .idle
    private(set) var isActive = false
    private var ownsNativeFullScreen = false
    private var exitAfterEntry = false

    @discardableResult
    func enter(isNativeFullScreen: Bool, toggle: () -> Bool) -> Bool {
        guard transition == .idle, !isActive else { return false }
        isActive = true
        ownsNativeFullScreen = !isNativeFullScreen
        guard !isNativeFullScreen else { return true }

        // Set the guard before sending the action: AppKit can notify observers
        // synchronously, and input arriving during the transition must not reverse it.
        transition = .entering
        guard toggle() else {
            nativeDidExit()
            return false
        }
        return true
    }

    @discardableResult
    func exit(toggle: () -> Bool) -> Bool {
        guard isActive else { return false }
        switch transition {
        case .entering:
            // Closing playback/Escape during entry must wait for AppKit to finish.
            exitAfterEntry = true
            return true
        case .exiting:
            return true
        case .idle:
            break
        }

        guard ownsNativeFullScreen else {
            isActive = false
            return true
        }
        transition = .exiting
        guard toggle() else {
            transition = .idle
            return false
        }
        return true
    }

    func nativeWillEnter() {
        transition = .entering
    }

    /// Returns whether playback requested an exit before entry completed.
    func nativeDidEnter() -> Bool {
        transition = .idle
        let shouldExit = exitAfterEntry
        exitAfterEntry = false
        return shouldExit
    }

    func nativeWillExit() {
        transition = .exiting
    }

    func nativeDidExit() {
        transition = .idle
        isActive = false
        ownsNativeFullScreen = false
        exitAfterEntry = false
    }

    func nativeDidFailToExit() {
        transition = .idle
        exitAfterEntry = false
    }
}
#endif
