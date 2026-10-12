//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// TODO: Button recognizers for tvOS?
//       - .menu, .select

public class UIPreferencesHostingController: UIHostingController<AnyView> {

    public init(@ViewBuilder content: @escaping () -> some View) {

        _ = UIViewController.swizzle

        let box = Box()
        let rootView = AnyView(
            content()
            #if os(iOS)
                .onPreferenceChange(KeyCommandsPreferenceKey.self) {
                    box.value?._keyCommandActions = $0
                }
                .onPreferenceChange(PrefersHomeIndicatorAutoHiddenPreferenceKey.self) {
                    box.value?._prefersHomeIndicatorAutoHidden = $0
                }
                .onPreferenceChange(PreferredScreenEdgesDeferringSystemGesturesPreferenceKey.self) {
                    box.value?._preferredScreenEdgesDeferringSystemGestures = $0
                }
                .onPreferenceChange(SupportedOrientationsPreferenceKey.self) {
                    box.value?._orientations = $0
                }
            #elseif os(tvOS)
                .onPreferenceChange(PressCommandsPreferenceKey.self) {
                    box.value?._pressCommandActions = $0
                }
            #endif
        )

        super.init(rootView: rootView)

        box.value = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if os(iOS)

    // MARK: Key Commands

    private var _keyCommandActions: [KeyCommandAction] = [] {
        willSet {
            _keyCommands = newValue.filter(\.allowsRepeat).map { action in
                let keyCommand = UIKeyCommand(
                    title: action.title,
                    action: #selector(keyCommandHit),
                    input: String(action.input),
                    modifierFlags: action.modifierFlags
                )

                keyCommand.subtitle = action.subtitle
                keyCommand.wantsPriorityOverSystemBehavior = true

                return keyCommand
            }
        }
    }

    private var _keyCommands: [UIKeyCommand] = []

    override public var keyCommands: [UIKeyCommand]? {
        _keyCommands
    }

    @objc
    private func keyCommandHit(keyCommand: UIKeyCommand) {
        guard let action = _keyCommandActions
            .first(where: { $0.input == keyCommand.input && $0.modifierFlags == keyCommand.modifierFlags }) else { return }
        action.action()
    }

    // UIKeyCommand uses UIKit's repeated-action timer. Window transitions can
    // cancel its key-up delivery, leaving a toggle command running indefinitely.
    // Non-repeating actions run after a physical release, so UIKit has finished
    // the press before the action can move its window to another macOS Space.
    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { nonRepeatingAction(for: $0) == nil }
        if !remaining.isEmpty {
            super.pressesBegan(remaining, with: event)
        }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let actions = presses.compactMap { nonRepeatingAction(for: $0) }
        let remaining = presses.filter { nonRepeatingAction(for: $0) == nil }
        if !remaining.isEmpty {
            super.pressesEnded(remaining, with: event)
        }
        // Finish UIKit's release dispatch before starting any window transition.
        DispatchQueue.main.async {
            actions.forEach { $0.action() }
        }
    }

    private func nonRepeatingAction(for press: UIPress) -> KeyCommandAction? {
        guard let key = press.key else { return nil }
        return _keyCommandActions.first {
            !$0.allowsRepeat && $0.input == key.charactersIgnoringModifiers && $0.modifierFlags == key.modifierFlags
        }
    }

    // MARK: Orientation

    var _orientations: UIInterfaceOrientationMask = .all {
        didSet {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        _orientations
    }

    override public var shouldAutorotate: Bool {
        true
    }

    // MARK: Defer Edges

    private var _preferredScreenEdgesDeferringSystemGestures: UIRectEdge = [.left, .right] {
        didSet { setNeedsUpdateOfScreenEdgesDeferringSystemGestures() }
    }

    override public var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        _preferredScreenEdgesDeferringSystemGestures
    }

    // MARK: Home Indicator Auto Hidden

    private var _prefersHomeIndicatorAutoHidden = false {
        didSet { setNeedsUpdateOfHomeIndicatorAutoHidden() }
    }

    override public var prefersHomeIndicatorAutoHidden: Bool {
        _prefersHomeIndicatorAutoHidden
    }
    #endif

    #if os(tvOS)

    override public func viewDidLoad() {
        super.viewDidLoad()

        let gesture = UITapGestureRecognizer(target: self, action: #selector(ignorePress))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(gesture)
    }

    @objc
    func ignorePress() {}

    private var _pressCommandActions: [PressCommandAction] = []

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let buttonPress = presses.first?.type else { return }

        guard let action = _pressCommandActions
            .first(where: { $0.press == buttonPress }) else { return }
        action.action()
    }
    #endif
}
