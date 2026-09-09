# App icon

The source is `ViewTheWord/Resources/AppIcon.icon`, an editable Icon Composer
document. Open it in Icon Composer from Finder or the Xcode project navigator.

The icon retains the VTW lettering and indigo identity. The three letters are
independent SVG outlines on a 1024 × 1024 canvas, so editing the document does not
require the original font. Icon Composer supplies the enclosure, glass lighting,
and shadows. The artwork contains no baked-in highlights, shadows, or outer mask.

The background runs from violet indigo to deep blue. The dark appearance uses a
midnight background and pale periwinkle lettering. Explicit monochrome fills
support the system's tinted and clear appearances. Keep the base and appearance
fills together in `fill-specializations`; a separate `fill` can override that
array in Icon Composer's decoder.

The Xcode target includes the document as an Icon Composer resource and keeps
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in both configurations. Build with
Xcode 26.5 or later. The asset compiler generates `Assets.car` for the layered icon
and `AppIcon.icns`; the app requires macOS 26.0 or later. There is no
second bitmap app icon to keep in sync.

Render all six macOS appearances with the Icon Composer renderer bundled with
the selected Xcode:

```bash
bash scripts/render-icon-review.sh
```

The 512-pixel PNGs are written to `build/icon-review`. An optional first argument
sets another output directory. Rendering may need to run outside a sandbox so
Icon Composer can use its native rendering services.

After changes, build Debug and Release and inspect the compiled `AppIcon.icns`
at small sizes as well as the full-size appearance previews. Preview renders do
not exercise the live lighting animation in Finder or the Dock.
