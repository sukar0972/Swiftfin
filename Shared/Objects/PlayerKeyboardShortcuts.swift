//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import UIKit

enum PlayerKeyAction: String, CaseIterable, Identifiable {
    case playPause
    case seekBackward
    case seekForward
    case toggleFullscreen
    case toggleAspectFill
    case previousItem
    case nextItem
    case decreasePlaybackSpeed
    case increasePlaybackSpeed
    case resetPlaybackSpeed
    case closePlayer
    case toggleSubtitles

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .playPause:
            L10n.playAndPause
        case .seekBackward:
            L10n.seekBackward
        case .seekForward:
            L10n.seekForward
        case .toggleFullscreen:
            L10n.toggleFullscreen
        case .toggleAspectFill:
            L10n.toggleAspectFitFill
        case .previousItem:
            L10n.previousItem
        case .nextItem:
            L10n.nextItem
        case .decreasePlaybackSpeed:
            L10n.decreasePlaybackSpeed
        case .increasePlaybackSpeed:
            L10n.increasePlaybackSpeed
        case .resetPlaybackSpeed:
            L10n.resetPlaybackSpeed
        case .closePlayer:
            L10n.closePlayer
        case .toggleSubtitles:
            L10n.toggleSubtitles
        }
    }

    /// Close, fullscreen, and subtitles stay non-repeating. A held key must
    /// not start another fullscreen transition before the first one finishes.
    var allowsRepeat: Bool {
        switch self {
        case .closePlayer, .toggleFullscreen, .toggleSubtitles:
            false
        default:
            true
        }
    }
}

struct PlayerKeyModifiers: OptionSet, Hashable, Codable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let command = PlayerKeyModifiers(rawValue: 1 << 0)
    static let shift = PlayerKeyModifiers(rawValue: 1 << 1)
    static let option = PlayerKeyModifiers(rawValue: 1 << 2)
    static let control = PlayerKeyModifiers(rawValue: 1 << 3)

    init(flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.command) {
            insert(.command)
        }
        if flags.contains(.shift) {
            insert(.shift)
        }
        if flags.contains(.alternate) {
            insert(.option)
        }
        if flags.contains(.control) {
            insert(.control)
        }
    }

    /// NSEvent modifier bits: shift 17, control 18, option 19, command 20.
    init(carbonFlags: UInt) {
        self = []
        if carbonFlags & (1 << 20) != 0 {
            insert(.command)
        }
        if carbonFlags & (1 << 17) != 0 {
            insert(.shift)
        }
        if carbonFlags & (1 << 19) != 0 {
            insert(.option)
        }
        if carbonFlags & (1 << 18) != 0 {
            insert(.control)
        }
    }

    var uiFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.command) {
            flags.insert(.command)
        }
        if contains(.shift) {
            flags.insert(.shift)
        }
        if contains(.option) {
            flags.insert(.alternate)
        }
        if contains(.control) {
            flags.insert(.control)
        }
        return flags
    }

    var symbolPrefix: String {
        var prefix = ""
        if contains(.control) {
            prefix += "⌃"
        }
        if contains(.option) {
            prefix += "⌥"
        }
        if contains(.shift) {
            prefix += "⇧"
        }
        if contains(.command) {
            prefix += "⌘"
        }
        return prefix
    }
}

enum PlayerKeyInput {
    static let escape = UIKeyCommand.inputEscape
    static let leftArrow = UIKeyCommand.inputLeftArrow
    static let rightArrow = UIKeyCommand.inputRightArrow
    static let upArrow = UIKeyCommand.inputUpArrow
    static let downArrow = UIKeyCommand.inputDownArrow
    static let pageUp = UIKeyCommand.inputPageUp
    static let pageDown = UIKeyCommand.inputPageDown
    static let home = UIKeyCommand.inputHome
    static let end = UIKeyCommand.inputEnd
    static let delete = UIKeyCommand.inputDelete
    static let forwardDelete = "\u{F728}"
    static let space = " "
    static let tab = "\t"
    static let `return` = "\r"
    // NSF1FunctionKey through NSF12FunctionKey. UIKeyCommand has no Swift inputF1 member.
    static let f1 = "\u{F704}"
    static let f2 = "\u{F705}"
    static let f3 = "\u{F706}"
    static let f4 = "\u{F707}"
    static let f5 = "\u{F708}"
    static let f6 = "\u{F709}"
    static let f7 = "\u{F70A}"
    static let f8 = "\u{F70B}"
    static let f9 = "\u{F70C}"
    static let f10 = "\u{F70D}"
    static let f11 = "\u{F70E}"
    static let f12 = "\u{F70F}"
}

struct PlayerKeyChord: Hashable, Codable {
    var input: String
    var modifiers: PlayerKeyModifiers

    var modifierFlags: UIKeyModifierFlags {
        modifiers.uiFlags
    }

    var symbol: String {
        modifiers.symbolPrefix + Self.symbol(for: input)
    }

    /// Command-Q, W, H, and M belong to the window. Recording leaves them alone.
    var yieldsToSystem: Bool {
        modifiers == .command && ["q", "w", "h", "m"].contains(input)
    }

    static let settings = PlayerKeyChord(input: ",", modifiers: .command)

    static func symbol(for input: String) -> String {
        switch input {
        case PlayerKeyInput.space:
            "Space"
        case PlayerKeyInput.escape:
            "Esc"
        case PlayerKeyInput.leftArrow:
            "←"
        case PlayerKeyInput.rightArrow:
            "→"
        case PlayerKeyInput.upArrow:
            "↑"
        case PlayerKeyInput.downArrow:
            "↓"
        case PlayerKeyInput.tab:
            "Tab"
        case PlayerKeyInput.return:
            "↩"
        case PlayerKeyInput.delete:
            "⌫"
        case PlayerKeyInput.forwardDelete:
            "⌦"
        case PlayerKeyInput.home:
            "Home"
        case PlayerKeyInput.end:
            "End"
        case PlayerKeyInput.pageUp:
            "Page Up"
        case PlayerKeyInput.pageDown:
            "Page Down"
        case PlayerKeyInput.f1:
            "F1"
        case PlayerKeyInput.f2:
            "F2"
        case PlayerKeyInput.f3:
            "F3"
        case PlayerKeyInput.f4:
            "F4"
        case PlayerKeyInput.f5:
            "F5"
        case PlayerKeyInput.f6:
            "F6"
        case PlayerKeyInput.f7:
            "F7"
        case PlayerKeyInput.f8:
            "F8"
        case PlayerKeyInput.f9:
            "F9"
        case PlayerKeyInput.f10:
            "F10"
        case PlayerKeyInput.f11:
            "F11"
        case PlayerKeyInput.f12:
            "F12"
        default:
            input.count == 1 ? input.uppercased() : input
        }
    }

    init(input: String, modifiers: PlayerKeyModifiers) {
        self.input = input
        self.modifiers = modifiers
    }

    init?(appKitEvent event: NSObject) {
        if let isRepeat = event.value(forKey: "isARepeat") as? NSNumber, isRepeat.boolValue {
            return nil
        }

        let characters = event.value(forKey: "charactersIgnoringModifiers") as? String ?? ""
        let flags = (event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0
        let keyCode = (event.value(forKey: "keyCode") as? NSNumber)?.uint16Value ?? 0
        guard let chord = Self.make(
            characters: characters,
            carbonModifierFlags: flags,
            virtualKeyCode: keyCode
        ) else { return nil }
        self = chord
    }

    init?(uiKey key: UIKey) {
        let modifiers = PlayerKeyModifiers(flags: key.modifierFlags)
        guard let input = Self.input(forHIDUsage: key.keyCode) ?? Self.normalized(key.charactersIgnoringModifiers) else {
            return nil
        }
        self.init(input: input, modifiers: modifiers)
    }

    private static func make(
        characters: String,
        carbonModifierFlags: UInt,
        virtualKeyCode: UInt16
    ) -> PlayerKeyChord? {
        let modifiers = PlayerKeyModifiers(carbonFlags: carbonModifierFlags)
        guard let input = input(forVirtualKeyCode: virtualKeyCode) ?? normalized(characters) else {
            return nil
        }
        return PlayerKeyChord(input: input, modifiers: modifiers)
    }

    /// Layout-independent Mac virtual key codes. Letter keys stay with the
    /// characters so the active keyboard layout is honored.
    private static func input(forVirtualKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 0x7B: PlayerKeyInput.leftArrow
        case 0x7C: PlayerKeyInput.rightArrow
        case 0x7D: PlayerKeyInput.downArrow
        case 0x7E: PlayerKeyInput.upArrow
        case 0x35: PlayerKeyInput.escape
        case 0x31: PlayerKeyInput.space
        case 0x33: PlayerKeyInput.delete
        case 0x24: PlayerKeyInput.return
        case 0x30: PlayerKeyInput.tab
        case 0x75: PlayerKeyInput.forwardDelete
        case 0x73: PlayerKeyInput.home
        case 0x77: PlayerKeyInput.end
        case 0x74: PlayerKeyInput.pageUp
        case 0x79: PlayerKeyInput.pageDown
        case 0x7A: PlayerKeyInput.f1
        case 0x78: PlayerKeyInput.f2
        case 0x63: PlayerKeyInput.f3
        case 0x76: PlayerKeyInput.f4
        case 0x60: PlayerKeyInput.f5
        case 0x61: PlayerKeyInput.f6
        case 0x62: PlayerKeyInput.f7
        case 0x64: PlayerKeyInput.f8
        case 0x65: PlayerKeyInput.f9
        case 0x6D: PlayerKeyInput.f10
        case 0x67: PlayerKeyInput.f11
        case 0x6F: PlayerKeyInput.f12
        default: nil
        }
    }

    private static func input(forHIDUsage usage: UIKeyboardHIDUsage) -> String? {
        switch usage {
        case .keyboardLeftArrow: PlayerKeyInput.leftArrow
        case .keyboardRightArrow: PlayerKeyInput.rightArrow
        case .keyboardUpArrow: PlayerKeyInput.upArrow
        case .keyboardDownArrow: PlayerKeyInput.downArrow
        case .keyboardEscape: PlayerKeyInput.escape
        case .keyboardSpacebar: PlayerKeyInput.space
        case .keyboardDeleteOrBackspace: PlayerKeyInput.delete
        case .keyboardDeleteForward: PlayerKeyInput.forwardDelete
        case .keyboardReturnOrEnter, .keypadEnter: PlayerKeyInput.return
        case .keyboardTab: PlayerKeyInput.tab
        case .keyboardHome: PlayerKeyInput.home
        case .keyboardEnd: PlayerKeyInput.end
        case .keyboardPageUp: PlayerKeyInput.pageUp
        case .keyboardPageDown: PlayerKeyInput.pageDown
        case .keyboardF1: PlayerKeyInput.f1
        case .keyboardF2: PlayerKeyInput.f2
        case .keyboardF3: PlayerKeyInput.f3
        case .keyboardF4: PlayerKeyInput.f4
        case .keyboardF5: PlayerKeyInput.f5
        case .keyboardF6: PlayerKeyInput.f6
        case .keyboardF7: PlayerKeyInput.f7
        case .keyboardF8: PlayerKeyInput.f8
        case .keyboardF9: PlayerKeyInput.f9
        case .keyboardF10: PlayerKeyInput.f10
        case .keyboardF11: PlayerKeyInput.f11
        case .keyboardF12: PlayerKeyInput.f12
        default: nil
        }
    }

    private static func normalized(_ characters: String) -> String? {
        guard !characters.isEmpty else { return nil }
        if characters.unicodeScalars.allSatisfy({ (0xF700 ... 0xF8FF).contains($0.value) }) {
            return nil
        }
        if characters.count == 1, let scalar = characters.unicodeScalars.first, CharacterSet.letters.contains(scalar) {
            return characters.lowercased()
        }
        return characters
    }
}

enum PlayerShortcutUpdate: Equatable {
    case updated(PlayerKeyboardShortcuts)
    case conflict(PlayerKeyAction)
    case reserved
}

struct PlayerKeyboardShortcuts: Hashable, Codable, Storable {
    var playPause: PlayerKeyChord
    var seekBackward: PlayerKeyChord
    var seekForward: PlayerKeyChord
    var toggleFullscreen: PlayerKeyChord
    var toggleAspectFill: PlayerKeyChord
    var previousItem: PlayerKeyChord
    var nextItem: PlayerKeyChord
    var decreasePlaybackSpeed: PlayerKeyChord
    var increasePlaybackSpeed: PlayerKeyChord
    var resetPlaybackSpeed: PlayerKeyChord
    var closePlayer: PlayerKeyChord
    var toggleSubtitles: PlayerKeyChord

    static let `default` = PlayerKeyboardShortcuts(
        playPause: PlayerKeyChord(input: PlayerKeyInput.space, modifiers: []),
        seekBackward: PlayerKeyChord(input: PlayerKeyInput.leftArrow, modifiers: []),
        seekForward: PlayerKeyChord(input: PlayerKeyInput.rightArrow, modifiers: []),
        toggleFullscreen: PlayerKeyChord(input: "f", modifiers: []),
        toggleAspectFill: PlayerKeyChord(input: "a", modifiers: []),
        previousItem: PlayerKeyChord(input: PlayerKeyInput.leftArrow, modifiers: .command),
        nextItem: PlayerKeyChord(input: PlayerKeyInput.rightArrow, modifiers: .command),
        decreasePlaybackSpeed: PlayerKeyChord(input: "[", modifiers: .command),
        increasePlaybackSpeed: PlayerKeyChord(input: "]", modifiers: .command),
        resetPlaybackSpeed: PlayerKeyChord(input: "\\", modifiers: .command),
        closePlayer: PlayerKeyChord(input: PlayerKeyInput.escape, modifiers: []),
        toggleSubtitles: PlayerKeyChord(input: "s", modifiers: [])
    )

    subscript(action: PlayerKeyAction) -> PlayerKeyChord {
        get {
            switch action {
            case .playPause: playPause
            case .seekBackward: seekBackward
            case .seekForward: seekForward
            case .toggleFullscreen: toggleFullscreen
            case .toggleAspectFill: toggleAspectFill
            case .previousItem: previousItem
            case .nextItem: nextItem
            case .decreasePlaybackSpeed: decreasePlaybackSpeed
            case .increasePlaybackSpeed: increasePlaybackSpeed
            case .resetPlaybackSpeed: resetPlaybackSpeed
            case .closePlayer: closePlayer
            case .toggleSubtitles: toggleSubtitles
            }
        }
        set {
            switch action {
            case .playPause: playPause = newValue
            case .seekBackward: seekBackward = newValue
            case .seekForward: seekForward = newValue
            case .toggleFullscreen: toggleFullscreen = newValue
            case .toggleAspectFill: toggleAspectFill = newValue
            case .previousItem: previousItem = newValue
            case .nextItem: nextItem = newValue
            case .decreasePlaybackSpeed: decreasePlaybackSpeed = newValue
            case .increasePlaybackSpeed: increasePlaybackSpeed = newValue
            case .resetPlaybackSpeed: resetPlaybackSpeed = newValue
            case .closePlayer: closePlayer = newValue
            case .toggleSubtitles: toggleSubtitles = newValue
            }
        }
    }

    func updating(_ action: PlayerKeyAction, to chord: PlayerKeyChord) -> PlayerShortcutUpdate {
        if chord == .settings {
            return .reserved
        }
        if let owner = PlayerKeyAction.allCases.first(where: { self[$0] == chord }), owner != action {
            return .conflict(owner)
        }

        var updated = self
        updated[action] = chord
        return .updated(updated)
    }
}
