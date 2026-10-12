//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

@main
private struct MacPlayerFullScreenTests {

    @MainActor
    static func main() {
        testNativeEntryAndExit()
        testExistingSpaceReuse()
        testRepeatedTransitionRequests()
        testSynchronousNotifications()
        testCloseDuringEntry()
        testFailedEntry()
        testFailedExit()
        testExternalWindowTransitions()
        print("8 native fullscreen regression scenarios passed")
    }

    @MainActor
    private static func testNativeEntryAndExit() {
        let player = MacPlayerFullScreen()
        var toggles = 0
        let toggle = { toggles += 1
            return true
        }
        for _ in 0 ..< 5 {
            precondition(player.enter(isNativeFullScreen: false, toggle: toggle))
            precondition(player.isActive && player.transition == .entering)
            precondition(!player.nativeDidEnter())
            precondition(player.exit(toggle: toggle))
            precondition(player.transition == .exiting)
            player.nativeDidExit()
            precondition(!player.isActive && player.transition == .idle)
        }
        precondition(toggles == 10)
    }

    @MainActor
    private static func testExistingSpaceReuse() {
        let player = MacPlayerFullScreen()
        let toggle: () -> Bool = { preconditionFailure("Never toggle a pre-existing native app Space") }
        precondition(player.enter(isNativeFullScreen: true, toggle: toggle))
        precondition(player.isActive && player.transition == .idle)
        precondition(player.exit(toggle: toggle))
        precondition(!player.isActive && player.transition == .idle)
    }

    @MainActor
    private static func testRepeatedTransitionRequests() {
        let player = MacPlayerFullScreen()
        var toggles = 0
        let toggle = { toggles += 1
            return true
        }
        precondition(player.enter(isNativeFullScreen: false, toggle: toggle))
        for _ in 0 ..< 20 {
            precondition(
                !player.enter(isNativeFullScreen: true, toggle: toggle),
                "The native style bit can become true before the Space transition completes"
            )
        }
        precondition(toggles == 1)
        precondition(!player.nativeDidEnter())
        precondition(player.exit(toggle: toggle))
        for _ in 0 ..< 20 {
            precondition(player.exit(toggle: toggle))
            precondition(!player.enter(isNativeFullScreen: false, toggle: toggle))
        }
        precondition(toggles == 2)
        player.nativeDidExit()
    }

    @MainActor
    private static func testSynchronousNotifications() {
        let player = MacPlayerFullScreen()
        precondition(player.enter(isNativeFullScreen: false) {
            precondition(player.transition == .entering)
            player.nativeWillEnter()
            precondition(!player.enter(isNativeFullScreen: false) { preconditionFailure() })
            return true
        })
        precondition(!player.nativeDidEnter())
        precondition(player.exit {
            precondition(player.transition == .exiting)
            player.nativeWillExit()
            precondition(player.exit { preconditionFailure() })
            return true
        })
        player.nativeDidExit()
    }

    @MainActor
    private static func testCloseDuringEntry() {
        let player = MacPlayerFullScreen()
        var toggles = 0
        let toggle = { toggles += 1
            return true
        }
        precondition(player.enter(isNativeFullScreen: false, toggle: toggle))
        precondition(player.exit(toggle: toggle))
        precondition(player.exit(toggle: toggle))
        precondition(toggles == 1, "Close during entry must wait rather than reverse AppKit's transition")
        precondition(player.nativeDidEnter())
        precondition(player.exit(toggle: toggle))
        precondition(toggles == 2 && player.transition == .exiting)
        player.nativeDidExit()
        precondition(!player.isActive)
    }

    @MainActor
    private static func testFailedEntry() {
        let player = MacPlayerFullScreen()
        precondition(!player.enter(isNativeFullScreen: false) { false })
        precondition(!player.isActive && player.transition == .idle)
        precondition(player.enter(isNativeFullScreen: false) { true })
        // A did-fail-to-enter notification uses the same reset as did-exit.
        player.nativeDidExit()
        precondition(!player.isActive && player.transition == .idle)
        precondition(player.enter(isNativeFullScreen: false) { true })
    }

    @MainActor
    private static func testFailedExit() {
        let player = MacPlayerFullScreen()
        precondition(player.enter(isNativeFullScreen: false) { true })
        precondition(!player.nativeDidEnter())
        precondition(!player.exit { false })
        precondition(player.isActive && player.transition == .idle)
        precondition(player.exit { true })
        player.nativeDidFailToExit()
        precondition(player.isActive && player.transition == .idle)
        precondition(player.exit { true })
        player.nativeDidExit()
    }

    @MainActor
    private static func testExternalWindowTransitions() {
        let player = MacPlayerFullScreen()
        player.nativeWillEnter()
        precondition(!player.enter(isNativeFullScreen: true) { preconditionFailure() })
        precondition(!player.nativeDidEnter())
        precondition(!player.isActive)
        precondition(player.enter(isNativeFullScreen: true) { preconditionFailure() })
        player.nativeWillExit()
        player.nativeDidExit()
        precondition(!player.isActive && player.transition == .idle)
        precondition(!player.exit { preconditionFailure() })
    }
}
