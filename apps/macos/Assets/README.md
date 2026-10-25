# SampleGlide brand assets

The current brand artwork was supplied by the project owner on 2026-10-25 in the SampleGlide logo package. These assets replace the previous generated app icon. Original SVGs are preserved unchanged under `Brand/`; their text is outlined, so displaying the logo does not require an external font or network request.

| Asset | Use |
| --- | --- |
| `Brand/sampleglide-icon.svg` | Source for the Dock / application icon |
| `Brand/sampleglide-lockup-dark.svg` | Light lettering for the dark app sidebar and dark README theme |
| `Brand/sampleglide-lockup-light.svg` | Dark lettering for the light README theme |
| Other SVGs in `Brand/` | Supplied monochrome mark, monochrome lockup, mark, and wordmark variants |
| `AppIcon.png` | 1024 × 1024 transparent PNG rendered from the supplied icon SVG |
| `BrandLogo.png` | 912 × 240 PNG rendered from the supplied dark lockup SVG, including its dark background |

The `SampleBrowserAssets` SwiftPM target bundles both PNGs. `AppArtwork.icon` and `AppArtwork.logo` load the resources from the embedded bundle, so the packaged app works without the checkout. `build-app.sh` converts `AppIcon.png` to ICNS, optionally compiles an Icon Composer asset catalog, and copies the resource bundle into `Contents/Resources` before signing.

The README uses the original light/dark SVGs in a `<picture>` element. It does not depend on PNG rendering or a remote image service.

## Re-render after replacing the original SVGs

The PNGs are checked in, so ordinary SwiftPM and app builds do not require a converter. To regenerate them after changing the supplied source, install librsvg and run from the repository root:

```sh
rsvg-convert --width 1024 --height 1024 --output apps/macos/Assets/AppIcon.png apps/macos/Assets/Brand/sampleglide-icon.svg
rsvg-convert --width 912 --height 240 --output apps/macos/Assets/BrandLogo.png apps/macos/Assets/Brand/sampleglide-lockup-dark.svg
```

`AppIcon.icon.json` describes the platform icon document structure, following [Apple's icon documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer). The supplied artwork itself is used unchanged. Command Line Tools and older Xcode builds keep the ICNS fallback.
