//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import PreferencesView
import SwiftUI

extension VideoPlayer {

    struct KeyCommandsModifier: ViewModifier {

        @Default(.VideoPlayer.jumpBackwardInterval)
        private var jumpBackwardInterval
        @Default(.VideoPlayer.jumpForwardInterval)
        private var jumpForwardInterval
        @Default(.VideoPlayer.keyboardShortcuts)
        private var keyboardShortcuts

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @Router
        private var router

        @Toaster
        private var toaster: ToastProxy

        func body(content: Content) -> some View {
            content
                .keyCommands {

                    // MARK: Close Player

                    keyCommand(.closePlayer) {
                        if UIDevice.isMac, MacWindowController.shared.handlePlayerEscape() {
                            return
                        }

                        manager.stop()
                        router.dismiss()
                    }

                    // MARK: Full Screen

                    keyCommand(.toggleFullscreen) {
                        MacWindowController.shared.togglePlayerFullScreen()
                    }

                    // Control–Command–F belongs to macOS's native window
                    // fullscreen command. Registering it here also starts a
                    // player transition while AppKit is changing Spaces.

                    // MARK: Settings

                    KeyCommandAction(
                        title: L10n.settings,
                        input: ",",
                        modifierFlags: .command
                    ) {
                        router.route(to: .settings)
                    }

                    // MARK: Aspect Fill

                    keyCommand(.toggleAspectFill) { @MainActor in
                        containerState.isAspectFilled.toggle()
                    }

                    keyCommand(.playPause) {
                        manager.togglePlayPause()

                        if !containerState.isPresentingOverlay {
                            if manager.playbackRequestStatus == .paused {
                                toaster.present(
                                    L10n.pause,
                                    systemName: "pause.circle"
                                )
                            } else if manager.playbackRequestStatus == .playing {
                                toaster.present(
                                    L10n.play,
                                    systemName: "play.circle"
                                )
                            }
                        }
                    }

                    // MARK: Subtitles

                    keyCommand(.toggleSubtitles) {
                        manager.playbackItem?.toggleSubtitles()
                    }

                    // MARK: - Decrease Playback Speed

                    keyCommand(.decreasePlaybackSpeed) {
                        let newRate = clamp(
                            manager.rate - 0.25,
                            min: 0.25,
                            max: 4
                        )

                        manager.setRate(rate: newRate)

                        toaster.present(
                            Text(newRate, format: .playbackRate),
                            systemName: VideoPlayerActionButton.playbackSpeed.systemImage
                        )
                    }

                    // MARK: - Increase Playback Speed

                    keyCommand(.increasePlaybackSpeed) {
                        let newRate = clamp(
                            manager.rate + 0.25,
                            min: 0.25,
                            max: 4
                        )

                        manager.setRate(rate: newRate)

                        toaster.present(
                            Text(newRate, format: .playbackRate),
                            systemName: VideoPlayerActionButton.playbackSpeed.systemImage
                        )
                    }

                    // MARK: Reset Playback Speed

                    keyCommand(.resetPlaybackSpeed) {
                        manager.setRate(rate: 1)
                        toaster.present(
                            Text(1, format: .playbackRate),
                            systemName: VideoPlayerActionButton.playbackSpeed.systemImage
                        )
                    }

                    // MARK: Play Next Item

                    keyCommand(.nextItem) {
                        guard let nextItem = manager.queue?.nextItem else { return }
                        manager.playNewItem(provider: nextItem)
                    }

                    // MARK: Play Previous Item

                    keyCommand(.previousItem) {
                        guard let previousItem = manager.queue?.previousItem else { return }
                        manager.playNewItem(provider: previousItem)
                    }

                    // MARK: - Jump Backward

                    keyCommand(.seekBackward) {
                        containerState.jumpProgressObserver.jumpBackward()
                        manager.proxy?.jumpBackward(jumpBackwardInterval.rawValue)

                        toaster.present(
                            Text(
                                jumpBackwardInterval.rawValue * containerState.jumpProgressObserver.jumps,
                                format: .minuteSecondsAbbreviated
                            ),
                            systemName: "gobackward"
                        )
                    }

                    // MARK: - Jump Forward

                    keyCommand(.seekForward) {
                        containerState.jumpProgressObserver.jumpForward()
                        manager.proxy?.jumpForward(jumpForwardInterval.rawValue)

                        toaster.present(
                            Text(
                                jumpForwardInterval.rawValue * containerState.jumpProgressObserver.jumps,
                                format: .minuteSecondsAbbreviated
                            ),
                            systemName: "goforward"
                        )
                    }
                }
        }

        private func keyCommand(
            _ action: PlayerKeyAction,
            perform: @escaping () -> Void
        ) -> KeyCommandAction {
            let chord = keyboardShortcuts[action]
            return KeyCommandAction(
                title: action.title,
                input: chord.input,
                modifierFlags: chord.modifierFlags,
                allowsRepeat: action.allowsRepeat,
                action: perform
            )
        }
    }
}
