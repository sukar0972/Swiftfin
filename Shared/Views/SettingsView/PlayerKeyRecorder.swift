//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import ObjectiveC
import SwiftUI
import UIKit

/// Captures the next shortcut while a settings row is waiting for one.
/// On Mac the AppKit monitor runs before the sheet treats Escape as dismiss.
struct PlayerKeyRecorder: UIViewControllerRepresentable {
    var isRecording: Bool
    var onChord: (PlayerKeyChord) -> Void

    func makeUIViewController(context: Context) -> PlayerKeyRecorderController {
        let controller = PlayerKeyRecorderController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: PlayerKeyRecorderController, context: Context) {
        controller.onChord = onChord
        controller.isRecording = isRecording
    }

    static func dismantleUIViewController(_ controller: PlayerKeyRecorderController, coordinator: ()) {
        controller.stop()
    }
}

final class PlayerKeyRecorderController: UIViewController {
    var onChord: ((PlayerKeyChord) -> Void)?
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                start()
            } else {
                stop()
            }
        }
    }

    private var monitor: AnyObject?

    func stop() {
        if let monitor {
            PlayerKeyEventMonitor.remove(monitor)
            self.monitor = nil
        }
        resignFirstResponder()
    }

    private func start() {
        guard monitor == nil else { return }
        guard ProcessInfo.processInfo.isMacCatalystApp else {
            becomeFirstResponderIfNeeded()
            return
        }

        monitor = PlayerKeyEventMonitor.addKeyDown { [weak self] event in
            guard let self, let chord = PlayerKeyChord(appKitEvent: event) else { return nil }
            if chord.yieldsToSystem {
                return event
            }
            self.deliver(chord)
            return nil
        }

        if monitor == nil {
            becomeFirstResponderIfNeeded()
        }
    }

    private func becomeFirstResponderIfNeeded() {
        guard isRecording else { return }
        if view.window == nil {
            DispatchQueue.main.async { [weak self] in
                self?.becomeFirstResponder()
            }
        } else {
            becomeFirstResponder()
        }
    }

    private func deliver(_ chord: PlayerKeyChord) {
        let deliver = { [weak self] in
            self?.onChord?(chord)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(deliver)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(deliver)
            }
        }
    }

    override var canBecomeFirstResponder: Bool {
        isRecording && monitor == nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isRecording, monitor == nil {
            becomeFirstResponderIfNeeded()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isRecording, monitor == nil else {
            super.pressesBegan(presses, with: event)
            return
        }

        let chords = presses.compactMap { press -> PlayerKeyChord? in
            guard let key = press.key else { return nil }
            return PlayerKeyChord(uiKey: key)
        }
        let accepted = chords.filter { !$0.yieldsToSystem }
        guard !accepted.isEmpty else {
            super.pressesBegan(presses, with: event)
            return
        }
        accepted.forEach(deliver)
    }
}

private enum PlayerKeyEventMonitor {
    private typealias MonitorBlock = @convention(block) (AnyObject) -> AnyObject?

    static func addKeyDown(_ handler: @escaping (NSObject) -> NSObject?) -> AnyObject? {
        guard let eventClass = NSClassFromString("NSEvent") else { return nil }
        let selector = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        guard let metaclass = object_getClass(eventClass),
              let implementation = class_getMethodImplementation(metaclass, selector)
        else { return nil }

        typealias Add = @convention(c) (AnyObject, Selector, UInt, @escaping MonitorBlock) -> AnyObject?
        let function = unsafeBitCast(implementation, to: Add.self)
        let block: MonitorBlock = { event in
            guard let object = event as? NSObject else { return event }
            return handler(object)
        }
        // NSEventMask.keyDown
        return function(eventClass, selector, 1 << 10, block)
    }

    static func remove(_ monitor: AnyObject) {
        guard let eventClass = NSClassFromString("NSEvent") else { return }
        let selector = NSSelectorFromString("removeMonitor:")
        _ = (eventClass as AnyObject).perform(selector, with: monitor)
    }
}
