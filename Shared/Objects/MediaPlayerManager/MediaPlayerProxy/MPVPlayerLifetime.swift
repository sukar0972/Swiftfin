//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if targetEnvironment(macCatalyst)
import Foundation
@preconcurrency import Libmpv
import QuartzCore

/// Stable C callback userdata. Its action captures the player weakly, so a
/// wakeup during shutdown cannot resurrect a player whose deinit has started.
final class MPVEventCallback: Sendable {

    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func signal() {
        Task { @MainActor [weak self] in
            self?.action()
        }
    }
}

/// Owns only the detached C handle and rendering resources, never the player.
/// The handle has a single worker after callback removal; UI resources remain
/// alive until mpv finishes, and are finally released on the main actor.
final class MPVPlayerShutdown: @unchecked Sendable {

    private struct Work: @unchecked Sendable {
        let handle: OpaquePointer
        let resources: Unmanaged<MPVPlayerShutdown>
    }

    private let handle: OpaquePointer
    private let metalLayer: CAMetalLayer
    private let eventCallback: MPVEventCallback?

    init(handle: OpaquePointer, metalLayer: CAMetalLayer, eventCallback: MPVEventCallback?) {
        self.handle = handle
        self.metalLayer = metalLayer
        self.eventCallback = eventCallback
    }

    func start() {
        // mpv serializes removal with any callback already in progress.
        mpv_set_wakeup_callback(handle, nil, nil)
        // Transfer one retain to the completion queue. Capturing self in both
        // closures could let the background closure perform the last release
        // if the main-queue completion happened to run first.
        let work = Work(handle: handle, resources: .passRetained(self))
        DispatchQueue.global(qos: .utility).async {
            // This blocks while decoder, audio, and rendering threads stop.
            // It must not run on the main actor during player dismissal.
            mpv_terminate_destroy(work.handle)
            DispatchQueue.main.async {
                work.resources.release()
            }
        }
    }
}
#endif
