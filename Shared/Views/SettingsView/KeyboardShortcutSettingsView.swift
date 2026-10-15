//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

struct KeyboardShortcutSettingsView: View {

    private enum Status: Equatable {
        case instructions
        case recording
        case conflict(String)
        case reserved
    }

    @Default(.VideoPlayer.keyboardShortcuts)
    private var shortcuts

    @State
    private var recording: PlayerKeyAction?

    @State
    private var status: Status = .instructions

    var body: some View {
        Form(systemImage: "keyboard") {
            Section {
                ForEach(PlayerKeyAction.allCases) { action in
                    shortcutRow(action)
                }
            } footer: {
                Text(footer)
            }

            Section {
                Button(L10n.reset) {
                    shortcuts = .default
                    recording = nil
                    status = .instructions
                }
                .disabled(shortcuts == .default)
            }
        }
        .navigationTitle(L10n.keyboardShortcuts.localizedCapitalized)
        .background {
            PlayerKeyRecorder(isRecording: recording != nil) { chord in
                guard let recording else { return }
                apply(chord, to: recording)
            }
        }
    }

    private var footer: String {
        switch status {
        case .instructions:
            L10n.keyboardShortcutsDescription
        case .recording:
            L10n.keyboardShortcutsRecording
        case let .conflict(name):
            L10n.keyboardShortcutInUse(name)
        case .reserved:
            L10n.keyboardShortcutReserved
        }
    }

    private func shortcutRow(_ action: PlayerKeyAction) -> some View {
        let isRecording = recording == action

        return Button {
            if isRecording {
                recording = nil
                status = .instructions
            } else {
                recording = action
                status = .recording
            }
        } label: {
            HStack {
                Text(action.title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(isRecording ? L10n.pressShortcut : shortcuts[action].symbol)
                    .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
            }
        }
        .foregroundStyle(.primary, isRecording ? Color.accentColor : Color.secondary)
        .accessibilityAddTraits(isRecording ? .isSelected : [])
    }

    private func apply(_ chord: PlayerKeyChord, to action: PlayerKeyAction) {
        switch shortcuts.updating(action, to: chord) {
        case let .updated(updated):
            shortcuts = updated
            recording = nil
            status = .instructions
        case let .conflict(owner):
            recording = nil
            status = .conflict(owner.title)
        case .reserved:
            recording = nil
            status = .reserved
        }
    }
}
