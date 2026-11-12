# Approved dsh-mobile-next brand assets

The user-selected uploads are preserved without redrawing:

- `promotion-original.png`: first upload, 1774 × 887; promotion artwork only.
- `app-icon-source.png`: second upload, 1254 × 1254; original launcher artwork.
- `app-icon-1024.png`: opaque RGB PNG, square, resized from the second upload.
- `app-icon-192.png` / `app-icon-512.png`: reusable smaller PNG exports.
- `launcher-preview.png`: original composition and simulated Android circle / rounded masks.

## App integration

Integrated into the existing Android Flutter application under `flutter/android/app/src/main/res/`:

- Legacy `ic_launcher.png`: mdpi 48px, hdpi 72px, xhdpi 96px, xxhdpi 144px, xxxhdpi 192px.
- Adaptive foreground and monochrome layers: 108 / 162 / 216 / 324 / 432px.
- API 26 adaptive icon XML; API 33 adaptive icon XML adds monochrome themed-icon support.
- Black background color resource.

The existing manifest already references `@mipmap/ic_launcher`; no manifest changes were necessary. The master PNG is also stored at `flutter/assets/app-icon.png` as source artwork; it need not be included as a Flutter runtime asset for Android launcher packaging.

Adaptive layers use the approved black-and-white artwork's luminance as alpha, keeping the phone and NEXT letter cutouts transparent above a black background. The whole-source placement is 62% of the 108dp canvas, keeping meaningful pixels within Android's central 66dp safe circle. Artwork is not cropped or redrawn. Android themed icons may change the black/white colors according to the user's system theme.

The old five Android launcher PNGs are retained in `original-android-icons/`. The macOS target has not been changed. This project does not currently include an iOS target; the 1024px master is ready for future iOS integration, but no iOS installation or configuration is claimed.

## Reproduction and checks

Run `python3 flutter/tool/generate_app_icons.py` from the workspace root with Pillow installed. `validation.json` records dimensions, image modes, PNG signatures, hashes and adaptive safe-circle validation.

A Flutter debug APK build was attempted. It failed on existing Dart compilation errors in `flutter/lib/src/ui/pairing_page.dart` (lines 73, 272, 703): invalid `context` / const localization expressions and a function passed where a String is expected. No unrelated Dart code was changed and no new APK was produced. Device installation / launcher verification remains pending.
