# Licensing scope and third-party components

SampleGlide's original source code, included documentation, generated app icon, and original synthetic signals created by the tests are offered under the root [MIT License](LICENSE). The copyright holder is identified by the public account name `bassmicrobe`. This license does not relicense third-party SDKs or audio supplied by users.

## macOS application

The Swift package declares no external Swift package dependencies. It uses Apple system frameworks, including SwiftUI, AppKit, AVFoundation, and system SQLite. Apple's SDK and platform terms remain applicable. No third-party source libraries, fonts, or sample packs are vendored here.

The generated app icon's provenance is documented in [the assets README](apps/macos/Assets/README.md). The icon artwork was generated for this application; references to Apple's icon documentation describe the platform asset format.

## Excluded components

The external design package, copied OpenAPI/JSON Schema specifications, SQL migrations derived from that package, and all Rust server/worker code are excluded from this public repository. Their redistribution rights are not established by this repository's MIT License. This macOS-only package does not include or link Symphonia or other Rust dependencies.

## Distribution

Retain the MIT copyright and permission notice when redistributing copies or substantial portions of the project. This repository publishes source, not a signed/notarized downloadable application or a server/container image. Any future binary release must preserve applicable notices and review the components actually included.
