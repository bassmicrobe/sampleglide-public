# SampleGlide application icon

`AppIcon.png` is the source artwork for the SampleGlide macOS app icon. It depicts stacked sample cards and a waveform on a dark graphite tile, using the app's lavender/cyan palette. The surrounding canvas is transparent.

The same PNG appears in the app's sidebar. The `SampleBrowserAssets` Swift package target bundles it for both `swift run` and packaged app builds, and `AppArtwork.bundle` provides the resource lookup. `build-app.sh` embeds the resource bundle in `Contents/Resources` before signing, so the UI does not depend on the checkout or `.build` directory at runtime.

Created on 2026-09-09 with the built-in `image_gen` tool. The app build converts this source into a complete `AppIcon.icns` and embeds it in `SampleGlide.app`. With Xcode 26 or newer, it also compiles a native Icon Composer asset catalog from `AppIcon.icon.json`, using the same PNG unchanged. No image-generation tool or network connection is needed for subsequent builds.

`AppIcon.icon.json` supplies a graphite background and a single artwork layer. The build stages it as an `.icon` document with the source PNG, then uses Apple's `actool` to create `Assets.car`. This avoids the extra white backing observed at large icon sizes with the ICNS-only build on the development Mac. Command Line Tools and older Xcode builds retain the ICNS fallback.

The document structure follows [Apple's alternate app icon sample](https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons). See [Apple's Icon Composer guide](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) for the native format. Only the document structure is reused; the artwork was generated for this app.

## Generation prompt

The original prompt below is preserved verbatim and uses the app's former name, Sample Browser. The artwork contains no text and is retained for SampleGlide.

```text
Use case: logo-brand. Asset type: final production macOS application icon, square 1024 by 1024 PNG, genuine transparent alpha outside the icon. Primary request: create an elegant memorable icon for Sample Browser, a professional macOS tool for exploring a personal library of audio samples, instant waveform audition, and dragging sounds into a DAW. Design a single frontal rounded-square dark graphite tile with smooth macOS-like continuous corners and a very restrained dimensional edge. Center a bold abstract mark combining a small stack of sample-library cards and an audio waveform: two understated offset lavender card outlines behind one primary rounded rectangular card, with five thick rounded vertical waveform bars on the front card. The waveform bars vary in height in a balanced rhythmic silhouette and transition from soft lavender on the left to pale icy cyan on the right. Design should read as an audio sample library, not a folder document, speaker, play-button app or equalizer dashboard. Style: refined native macOS icon, precise simple geometry, subtle satin materials and controlled soft highlights, nearly flat frontal composition. Strong silhouette, spacious composition, clear at 32 pixels. Color palette: near-black graphite #191B24, soft lavender #AC9CFF, icy cyan #76DAEC. The rounded-square tile occupies about 86 percent of the full square canvas, centered with equal transparent outer margins, no external backdrop. Keep all small secondary details minimal; use bold substantial shapes. No letters, words, numbers, typography, brand names, watermark, mockup scene, devices, perspective tilt, excessive bloom, rainbow gradients, neon glow or decorative particles. Deliver exactly one centered finished application icon on actual transparency, not a grid of variants.
```
