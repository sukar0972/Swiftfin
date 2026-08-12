//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if targetEnvironment(macCatalyst)

import Combine
import Defaults
import Foundation
@preconcurrency import JellyfinAPI
@preconcurrency import Libmpv
import QuartzCore
import SwiftUI
import UIKit

/// A libmpv-backed player for Mac Catalyst. mpv renders directly into a
/// CAMetalLayer while Swiftfin continues to own the controls and window UI.
@MainActor
final class MPVMediaPlayerProxy: VideoMediaPlayerProxy, MediaPlayerOffsetConfigurable {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    private let metalLayer = MPVMetalLayer()
    private var mpv: OpaquePointer?
    private var pollTimer: Timer?
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?
    private var isLoading = false
    private var lastPauseState: Bool?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var observer in observers {
                observer.manager = manager
            }

            managerItemObserver?.cancel()
            managerStateObserver?.cancel()

            guard let manager else { return }

            managerItemObserver = manager.$playbackItem
                .sink { [weak self] item in
                    guard let item else { return }
                    self?.playNew(item: item)
                }

            managerStateObserver = manager.$state
                .sink { [weak self] state in
                    if state == .stopped {
                        self?.stop()
                    }
                }
        }
    }

    var observers: [any MediaPlayerObserver] = [NowPlayableObserver()]

    init() {
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor

        guard let handle = mpv_create() else { return }
        mpv = handle

        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        setOption("video-rotate", "no")

        var windowID = Int64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID)

        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            mpv = nil
            return
        }

        mpv_request_log_messages(handle, "info")
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let proxy = Unmanaged<MPVMediaPlayerProxy>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                proxy.drainEvents()
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollState() }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let mpv {
            mpv_terminate_destroy(mpv)
        }
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func stop() {
        command("stop")
    }

    func jumpForward(_ seconds: Duration) {
        command("seek", String(seconds.seconds), "relative+exact")
    }

    func jumpBackward(_ seconds: Duration) {
        command("seek", String(-seconds.seconds), "relative+exact")
    }

    func setSeconds(_ seconds: Duration) {
        command("seek", String(seconds.seconds), "absolute+exact")
    }

    func setRate(_ rate: Float) {
        setDouble("speed", Double(rate))
    }

    func setAudioStream(_ stream: MediaStream) {
        guard let index = stream.index else { return }
        setInt("aid", Int64(index + 1))
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let index = stream.index, index >= 0 else {
            setString("sid", "no")
            return
        }
        setInt("sid", Int64(index + 1))
    }

    func setAudioOffset(_ seconds: Duration) {
        setDouble("audio-delay", seconds.seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        setDouble("sub-delay", seconds.seconds)
    }

    func setAspectFill(_ aspectFill: Bool) {
        setDouble("panscan", aspectFill ? 1 : 0)
    }

    var videoPlayerBody: some View {
        MPVPlayerView(metalLayer: metalLayer)
    }

    private func playNew(item: MediaPlayerItem) {
        guard mpv != nil else {
            manager?.error(ErrorMessage("Unable to initialize libmpv"))
            return
        }

        isLoading = true
        lastPauseState = nil
        let startSeconds = max(.zero, (item.baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))
        // mpv 0.40+ accepts an optional playlist index before per-file options.
        command("loadfile", item.url.absoluteString, "replace", "-1", "start=\(startSeconds.seconds)")
        play()
    }

    private func pollState() {
        guard mpv != nil else { return }

        let paused = getFlag("pause")
        let idle = getFlag("core-idle")
        let buffering = getFlag("paused-for-cache")
        isBuffering.value = buffering

        if let seconds = getDouble("time-pos"), seconds.isFinite {
            manager?.seconds = .seconds(seconds)
            isLoading = false
        }

        if let width = getDouble("video-params/w"),
           let height = getDouble("video-params/h"),
           width > 0,
           height > 0
        {
            videoSize.value = CGSize(width: width, height: height)
        }

        if paused != lastPauseState, !isLoading {
            lastPauseState = paused
            manager?.setPlaybackRequestStatus(status: paused || idle ? .paused : .playing)
        }

        if getFlag("eof-reached") {
            manager?.setPlaybackRequestStatus(status: .paused)
        }
    }

    private func drainEvents() {
        guard let mpv else { return }

        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                isLoading = false
                lastPauseState = false
                manager?.setPlaybackRequestStatus(status: .playing)

            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { break }
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    manager?.error(ErrorMessage("libmpv playback error: \(message)"))
                }

            case MPV_EVENT_LOG_MESSAGE:
                guard let data = event.pointee.data else { break }
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                if let prefix = message.prefix, let level = message.level, let text = message.text {
                    print("[libmpv:\(String(cString: prefix))] \(String(cString: level)): \(String(cString: text))", terminator: "")
                }

            default:
                break
            }
        }
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func setInt(_ name: String, _ value: Int64) {
        guard let mpv else { return }
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &value)
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var value: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var value = 0.0
        guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private func command(_ arguments: String...) {
        guard let mpv else { return }
        var pointers: [UnsafePointer<CChar>?] = arguments.map {
            UnsafePointer<CChar>(strdup($0))
        }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        mpv_command(mpv, &pointers)
    }
}

private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

private struct MPVPlayerView: UIViewRepresentable {
    let metalLayer: CAMetalLayer

    func makeUIView(context: Context) -> UIView {
        MPVRenderView(metalLayer: metalLayer)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class MPVRenderView: UIView {
    private let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: bounds.width * (window?.screen.scale ?? UIScreen.main.scale),
            height: bounds.height * (window?.screen.scale ?? UIScreen.main.scale)
        )
    }
}

#endif
