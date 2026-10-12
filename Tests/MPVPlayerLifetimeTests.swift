//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@preconcurrency import Libmpv
import QuartzCore

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var owners = 0
    private var layers = 0
    private var drains = 0

    var values: (owners: Int, layers: Int, drains: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (owners, layers, drains)
    }

    func ownerReleased() {
        lock.lock()
        owners += 1
        lock.unlock()
    }

    func layerReleased() {
        precondition(Thread.isMainThread, "Release rendering resources on the main thread")
        lock.lock()
        layers += 1
        lock.unlock()
    }

    func eventsDrained() {
        lock.lock()
        drains += 1
        lock.unlock()
    }
}

private final class TestMetalLayer: CAMetalLayer {
    private let counts: Counts

    init(counts: Counts) {
        self.counts = counts
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        counts.layerReleased()
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
private final class TestPlayer {
    private let handle: OpaquePointer
    private let counts: Counts
    private var callback: MPVEventCallback?
    let layer: TestMetalLayer

    init(counts: Counts) {
        self.counts = counts
        layer = TestMetalLayer(counts: counts)
        guard let handle = mpv_create() else { fatalError("mpv_create failed") }
        self.handle = handle
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "vo", "null")
        mpv_set_option_string(handle, "ao", "null")
        precondition(mpv_initialize(handle) >= 0)

        let callback = MPVEventCallback { [weak self] in
            self?.drainEvents()
        }
        self.callback = callback
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVEventCallback>.fromOpaque(context).takeUnretainedValue().signal()
        }, Unmanaged.passUnretained(callback).toOpaque())
    }

    func queueWakeups() {
        for _ in 0 ..< 100 {
            callback?.signal()
        }
        mpv_wakeup(handle)
    }

    func createExtraClient() -> OpaquePointer {
        guard let client = mpv_create_client(handle, "delayed-shutdown") else {
            fatalError("mpv_create_client failed")
        }
        return client
    }

    private func drainEvents() {
        counts.eventsDrained()
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
    }

    deinit {
        // Reproduce the exact dangerous timing: a wakeup while the owner's
        // deinit is already running. The callback must not retain the owner.
        callback?.signal()
        MPVPlayerShutdown(handle: handle, metalLayer: layer, eventCallback: callback).start()
        counts.ownerReleased()
    }
}

@main
private struct MPVPlayerLifetimeTests {
    private struct ExtraClient: @unchecked Sendable {
        let handle: OpaquePointer
    }

    @MainActor
    static func main() async {
        await testLiveEvents()
        await testDismissalWithPendingWakeups()
        await testSlowShutdownKeepsMainActorFree()
        print("mpv lifetime tests passed: live events, 24 teardown races, and nonblocking shutdown")
    }

    @MainActor
    private static func testLiveEvents() async {
        let counts = Counts()
        var player: TestPlayer? = TestPlayer(counts: counts)
        let owner = WeakReference(player!)
        let layer = WeakReference(player!.layer)
        player!.queueWakeups()
        try? await Task.sleep(for: .milliseconds(30))
        precondition(counts.values.drains > 0, "Deliver events while the player is alive")
        player = nil
        precondition(owner.value == nil, "Queued callbacks must not keep the player alive")
        await waitForRelease([layer], counts: counts, expected: 1)
    }

    @MainActor
    private static func testDismissalWithPendingWakeups() async {
        let counts = Counts()
        var layers: [WeakReference<TestMetalLayer>] = []
        for _ in 0 ..< 24 {
            var player: TestPlayer? = TestPlayer(counts: counts)
            let owner = WeakReference(player!)
            layers.append(WeakReference(player!.layer))
            player!.queueWakeups()
            player = nil
            precondition(owner.value == nil, "Do not resurrect an owner during deinit")
        }
        await waitForRelease(layers, counts: counts, expected: 24)
        precondition(counts.values.drains == 0, "Discard pending events after their player has gone away")
    }

    @MainActor
    private static func testSlowShutdownKeepsMainActorFree() async {
        let counts = Counts()
        var player: TestPlayer? = TestPlayer(counts: counts)
        let layer = WeakReference(player!.layer)
        let extraClient = ExtraClient(handle: player!.createExtraClient())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            mpv_destroy(extraClient.handle)
        }

        let start = ProcessInfo.processInfo.systemUptime
        player = nil
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.15, "Do not wait for mpv shutdown on the main actor")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(layer.value != nil, "Keep the rendering surface alive until mpv has stopped")
        await waitForRelease([layer], counts: counts, expected: 1)
    }

    @MainActor
    private static func waitForRelease(_ layers: [WeakReference<TestMetalLayer>], counts: Counts, expected: Int) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while layers.contains(where: { $0.value != nil }), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(layers.allSatisfy { $0.value == nil }, "Release detached rendering resources after shutdown")
        precondition(counts.values.owners == expected && counts.values.layers == expected)
    }
}
