<div align="center">
  <img alt="Swiftfin for Mac" src="./Resources/primary-wide.svg">
</div>

<div align="left">
  <h1>Swiftfin</h1>
  <img src="https://img.shields.io/badge/Mac-16+-red"/>
  <img src="https://img.shields.io/badge/Jellyfin-10.11-9962be"/>
  
  <a href="https://translate.jellyfin.org/engage/swiftfin/">
    <img src="https://translate.jellyfin.org/widgets/swiftfin/-/svg-badge.svg"/>
  </a>
</div>

<p align="center">
  <b>Swiftfin</b> is a modern video client for the <a href="https://github.com/jellyfin/jellyfin">Jellyfin</a> media server. Made using Swift to maximize direct play on Mac.
</p>

## About this fork

This is a native MacOS that converts Swiftfin from a shared iOS/tvOS application into a standalone Mac Catalyst app called Swiftfin Mac.

- Replaced MobileVLCKit/VLC with libmpv through MPVKit
- Removed the native AVPlayer playback option
- Enforced Jellyfin Direct Play only

Other functionality has been intentionally preserved.

## Download

[Download the latest Swiftfin Mac beta](https://github.com/sukar0972/Swiftfin/releases/download/swiftfin-mac-v1.0.0-beta.2/Swiftfin-Mac-1.0.0-beta.2.zip)

> [!WARNING]
> Swiftfin Mac is still in beta and is not Apple-notarized. After extracting
> the ZIP, right-click **Swiftfin Mac.app**, select **Open**, and confirm the
> prompt.

## 📖 Documentation

Swiftfin provides detailed documentation to help you understand key aspects of the app and its development approach:

- [🎞️ Library Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/libraries.md) — Information on **library compatibility** and supported media types in Swiftin.
- [🎬 Media Playback](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md) — Learn about Swiftfin's **Native** and **Swiftfin** players and how their features vary.
- [🧩 OS Version Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/version.md) — Read about how we determine the **minimum supported OS** and which versions of iOS & tvOS are supported.
- [💜 Supporting Development](https://jellyfin.org/docs/general/contributing/direct-donations) — Learn how you can **support the project developers** and help keep Swiftfin improving.

## ⚙️ Development

Thank you for your interest in Swiftfin! Please check out the [Contribution Guidelines](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/contributing.md) to get started.

## 📚 Translations

**Don't see Swiftfin in your language?**

Check out our [Weblate instance](https://translate.jellyfin.org/projects/swiftfin/) to help translate Swiftfin and other Jellyfin projects.

<a href="https://translate.jellyfin.org/engage/swiftfin/">
<img src="https://translate.jellyfin.org/widgets/swiftfin/-/multi-auto.svg"/>
</a>
