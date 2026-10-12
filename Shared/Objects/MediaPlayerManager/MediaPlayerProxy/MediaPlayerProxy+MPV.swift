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
import FactoryKit
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
    private let aspectFill = PublishedBox(initialValue: false)
    private var mpv: OpaquePointer?
    private var eventCallback: MPVEventCallback?
    private var pollTimer: Timer?
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?
    private var managerRateObserver: AnyCancellable?
    private var currentItem: MediaPlayerItem?
    private var sidecarURLs: [Int: String] = [:]
    private var hasReportedEnd = false
    private var isLoading = false
    private var lastPauseState: Bool?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var observer in observers {
                observer.manager = manager
            }

            managerItemObserver?.cancel()
            managerStateObserver?.cancel()
            managerRateObserver?.cancel()

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

            managerRateObserver = manager.$rate
                .sink { [weak self] rate in
                    self?.setRate(rate)
                }
        }
    }

    var observers: [any MediaPlayerObserver] = [NowPlayableObserver()]

    init() {
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.configureCanvas(UIScreen.main.nativeBounds.size)
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
        // The host view owns aspect fit/fill. The MoltenVK context has no
        // resize control implementation, so its render canvas stays fixed.
        setOption("keepaspect", "no")

        var windowID = Int64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID)

        guard mpv_initialize(handle) >= 0 else {
            mpv = nil
            MPVPlayerShutdown(handle: handle, metalLayer: metalLayer, eventCallback: nil).start()
            return
        }

        mpv_request_log_messages(handle, "info")
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_NONE)
        let eventCallback = MPVEventCallback { [weak self] in
            self?.drainEvents()
        }
        self.eventCallback = eventCallback
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVEventCallback>.fromOpaque(context).takeUnretainedValue().signal()
        }, Unmanaged.passUnretained(eventCallback).toOpaque())

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollState() }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let mpv {
            MPVPlayerShutdown(handle: mpv, metalLayer: metalLayer, eventCallback: eventCallback).start()
        }
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func stop() {
        currentItem = nil
        sidecarURLs = [:]
        isLoading = true
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
        if index < 0 {
            setString("aid", "no")
        } else {
            setInt("aid", Int64(index))
        }
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let index = stream.index, index >= 0 else {
            setString("sid", "no")
            return
        }
        setInt("sid", Int64(index))
    }

    func setAudioOffset(_ seconds: Duration) {
        setDouble("audio-delay", seconds.seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        setDouble("sub-delay", seconds.seconds)
    }

    func setAspectFill(_ aspectFill: Bool) {
        self.aspectFill.value = aspectFill
    }

    var videoPlayerBody: some View {
        MPVPlayerView(metalLayer: metalLayer, videoSize: videoSize, aspectFill: aspectFill)
    }

    private func playNew(item: MediaPlayerItem) {
        guard mpv != nil else {
            manager?.error(ErrorMessage("Unable to initialize libmpv"))
            return
        }

        isLoading = true
        // Size the canvas once per file, before mpv creates its video output.
        // Resizing the presentation layer then leaves the Vulkan swapchain and
        // mpv viewport in agreement throughout fullscreen animations.
        if let stream = item.videoStreams.first, let width = stream.width, let height = stream.height,
           width > 0, height > 0
        {
            var size = CGSize(width: width, height: height)
            if let ratio = stream.aspectRatio {
                let parts = ratio.split(separator: ":").compactMap { Double($0) }
                let value = parts.count == 2 ? parts[0] / parts[1] : Double(ratio)
                if let value, value.isFinite, value > 0 {
                    size.width = size.height * value
                }
            }
            videoSize.value = size
            let screen = UIScreen.main.nativeBounds.size
            let scale = min(1, min(screen.width / size.width, screen.height / size.height))
            metalLayer.configureCanvas(CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale)))
        }
        currentItem = item
        sidecarURLs = [:]
        hasReportedEnd = false
        lastPauseState = nil
        setRate(manager?.rate ?? Defaults[.VideoPlayer.Playback.playbackRate])
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

        if !isLoading, let seconds = getDouble("time-pos"), seconds.isFinite {
            manager?.seconds = .seconds(seconds)
        }

        if let width = getDouble("video-params/dw"),
           let height = getDouble("video-params/dh"),
           width > 0,
           height > 0
        {
            let size = CGSize(width: width, height: height)
            if videoSize.value != size {
                videoSize.value = size
            }
        }

        if paused != lastPauseState, !isLoading {
            lastPauseState = paused
            manager?.setPlaybackRequestStatus(status: paused || idle ? .paused : .playing)
        }

        if getFlag("eof-reached"), !isLoading, currentItem != nil {
            manager?.setPlaybackRequestStatus(status: .paused)
            reportEnd()
        }
    }

    private func reportEnd() {
        guard !isLoading, !hasReportedEnd, let currentItem, !currentItem.baseItem.isLiveStream else { return }
        hasReportedEnd = true
        manager?.ended()
    }

    private func loadSidecarSubtitles(for item: MediaPlayerItem) {
        guard let session = Container.shared.currentUserSession() else { return }
        for stream in item.subtitleStreams.sidecarSubtitles {
            guard let index = stream.index, let path = stream.deliveryURL,
                  let url = session.client.url(path: path)
            else { continue }
            sidecarURLs[index] = url.absoluteString
            command("sub-add", url.absoluteString, "auto", stream.displayTitle ?? "", stream.language ?? "", asynchronous: true)
        }
    }

    /// Translate container stream indexes to mpv's per-type IDs after loading.
    /// Rebuild from the source each time because sidecars arrive asynchronously.
    private func resolveTracks() {
        guard !isLoading, let item = currentItem,
              let count = getInt("track-list/count")
        else { return }

        let containerMap = MediaTrackIndexMap.build(
            from: item.mediaSource.mediaStreams ?? [],
            for: item.mediaSource.transcodingURL == nil ? .directPlay : .transcode,
            selectedAudioStreamIndex: item.selectedAudioStreamIndex ?? 0
        )
        var playerMap = MediaTrackIndexMap()
        for position in 0 ..< count {
            let prefix = "track-list/\(position)"
            guard let id = getInt("\(prefix)/id"), let type = getString("\(prefix)/type") else { continue }
            if getFlag("\(prefix)/external") {
                if type == "sub", let filename = getString("\(prefix)/external-filename") {
                    for (index, url) in sidecarURLs where url == filename {
                        playerMap.setPlayerIndex(Int(id), for: index)
                    }
                }
            } else if let containerIndex = getInt("\(prefix)/ff-index") {
                let streams = type == "audio" ? item.audioStreams : (type == "sub" ? item.subtitleStreams : item.videoStreams)
                for stream in streams where stream.isExternal != true {
                    guard let index = stream.index,
                          containerMap.playerIndex(for: index) == Int(containerIndex)
                    else { continue }
                    playerMap.setPlayerIndex(Int(id), for: index)
                }
            }
        }
        item.setPlayerTrackIndexes(playerMap)
        item.switchTrack(type: .audio, index: item.selectedAudioStreamIndex)
        item.switchTrack(type: .subtitle, index: item.selectedSubtitleStreamIndex)
    }

    private func drainEvents() {
        guard let mpv else { return }

        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                guard let item = currentItem else { break }
                isLoading = false
                loadSidecarSubtitles(for: item)
                resolveTracks()
                lastPauseState = false
                manager?.setPlaybackRequestStatus(status: .playing)

            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { break }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                if let name = property.name, String(cString: name) == "track-list" {
                    resolveTracks()
                }

            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { break }
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    manager?.error(ErrorMessage("libmpv playback error: \(message)"))
                } else if endFile.reason == MPV_END_FILE_REASON_EOF {
                    reportEnd()
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

    private func getInt(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func command(_ arguments: String..., asynchronous: Bool = false) {
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
        if asynchronous {
            mpv_command_async(mpv, 0, &pointers)
        } else {
            mpv_command(mpv, &pointers)
        }
    }
}

private final class MPVMetalLayer: CAMetalLayer {
    // mpvkit's MoltenVK context only reads drawableSize when configuring a
    // file. Letting it change with the window leaves a stale video viewport
    // in a larger drawable, producing black strips on the right and bottom.
    func configureCanvas(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        super.drawableSize = size
    }

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {} // UIKit and MoltenVK must not resize the per-file render canvas.
    }
}

private struct MPVPlayerView: UIViewRepresentable {
    let metalLayer: MPVMetalLayer

    @ObservedObject
    var videoSize: PublishedBox<CGSize>
    @ObservedObject
    var aspectFill: PublishedBox<Bool>

    func makeUIView(context: Context) -> MPVRenderView {
        MPVRenderView(metalLayer: metalLayer)
    }

    func updateUIView(_ uiView: MPVRenderView, context: Context) {
        uiView.updateGeometry(videoSize: videoSize.value, aspectFill: aspectFill.value)
    }
}

private final class MPVRenderView: UIView {
    private let metalLayer: CAMetalLayer
    private var videoSize: CGSize = .zero
    private var aspectFill = false

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        metalLayer.contentsGravity = .resize
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateGeometry(videoSize: CGSize, aspectFill: Bool) {
        guard self.videoSize != videoSize || self.aspectFill != aspectFill else { return }
        self.videoSize = videoSize
        self.aspectFill = aspectFill
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var frame = bounds
        if videoSize.width > 0, videoSize.height > 0 {
            let widthScale = bounds.width / videoSize.width
            let heightScale = bounds.height / videoSize.height
            let scale = aspectFill ? max(widthScale, heightScale) : min(widthScale, heightScale)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = frame
        CATransaction.commit()
    }
}

#endif
