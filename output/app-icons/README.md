# Voyager and Gaia icon assets

Approved matching spacecraft artwork, exported for Windows and Android. Assets only: no application code, manifests or existing icons were replaced. Gaia's textured surfaces and Voyager's approved front-facing view are preserved in the large icons.

Open [preview.png](preview.png) to compare the apps, Windows sizes, Android masks, themed icons and notification silhouettes.

## Included for each app

| Asset | Sizes in pixels | Location |
| --- | --- | --- |
| Windows multi-image ICO | 16, 20, 24, 32, 40, 48, 64, 256 | `<app>/windows/<app>.ico` |
| Individual Windows PNGs | Same eight sizes | `<app>/windows/png/` |
| Legacy Android launcher | 48, 72, 96, 144, 192 | `<app>/android/res/mipmap-*/` |
| Legacy round Android launcher | 48, 72, 96, 144, 192 | Same, with `_round` suffix |
| Adaptive foreground, background and monochrome | 108, 162, 216, 324, 432 | Same, with layer suffixes |
| Adaptive resource XML | Android 8+ and Android 13+ | `mipmap-anydpi-v26/`, `mipmap-anydpi-v33/` |
| Notification silhouette, white with alpha | 24, 36, 48, 72, 96 | `<app>/android/res/drawable-*/ic_stat_<app>.png` |
| Square opaque store artwork | 512 | `<app>/store/icon-512.png` |
| Full-size square icon, foreground and background masters | 1024 | `<app>/masters/` |

Density order is mdpi, hdpi, xhdpi, xxhdpi, xxxhdpi. Round icons are extra convenience assets. Android applies the mask to adaptive icons; the full-bleed adaptive background has no baked-in rounded corners. The full foreground, including the gold star and Voyager booms, fits inside a **64dp diameter circle on a 108dp canvas**, leaving a guard inside the official 66dp safe circle.

The 16, 20 and 24px Windows icons use separately drawn, simplified spacecraft with thicker details. They are intentionally less detailed than the large artwork. Notification and themed monochrome layers are separately drawn silhouettes with transparent cutouts, not color-to-white conversions of a square launcher. The notification mark omits the decorative star to give the spacecraft the space available in the status bar.

The ICO files contain eight 32-bit RGBA PNG-compressed frames, including all intermediate sizes. This format targets modern Windows. These assets cover the requested classic Windows desktop app and Android targets. Microsoft Store/MSIX tile assets and other platforms would be separate deliverables if needed.

## Integration handoff

Both resource sets can coexist in the same Android `res` tree: Voyager uses `ic_launcher`, and Gaia uses `ic_gaia`. Copy the contents of both `<app>/android/res/` directories into `android/app/src/main/res/`, merging directories. The background alias XML filenames are app-specific, so they also coexist without overwriting each other.

Voyager's manifest can keep `android:icon="@mipmap/ic_launcher"`; optionally add `android:roundIcon="@mipmap/ic_launcher_round"`. Gaia's separate application, activity alias, or shortcut can reference `@mipmap/ic_gaia` and `@mipmap/ic_gaia_round`. A Gaia asset alone does not create another home-screen entry; that needs application/alias/shortcut wiring and a launch route. No alias or shortcut is created by this package.

For flutter_local_notifications, use `AndroidInitializationSettings('ic_stat_voyager')` for the Android default and `icon: 'ic_stat_gaia'` on Gaia notifications where appropriate. These are **drawable** resources. Do not continue using `@mipmap/ic_launcher` as the small notification icon. The assets do not change notification code by themselves.

For Voyager on Windows, the existing consumers found in this checkout are `windows/runner/resources/app_icon.ico` and `assets/app_icon.ico`. The latter is used by the tray/notification path. Copy `voyager/windows/voyager.ico` to both locations when integrating. Gaia's Windows ICO is prepared separately; connect it to Gaia's window, tray or application identity as needed. An ICO file by itself does not establish a separate Windows app identity.

Gaia's in-app nav entry still uses its existing glyph. Image registration, Flutter UI changes and launch routing are outside this asset export.

## Sources and reproducibility

The original approved presentations from the built-in imagegen tool are preserved under `source/`:

- `approved-voyager-pair.png`: source for the unchanged Voyager illustration.
- `approved-textured-gaia-pair.png`: source for the final textured Gaia illustration.

These were not regenerated during export. The exporter separates their foregrounds, creates matching square navy gradient backgrounds, and packages the platform assets. The large spacecraft artwork is raster-based; there is no claim that these are editable vector masters. The simplified small-size drawings are defined in the exporter.

Regenerate from the repository root with Windows PowerShell and System.Drawing, with no third-party packages:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export_app_icons.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate_app_icons.ps1
```

The `-ExecutionPolicy` flag applies only to that PowerShell process; it does not change the machine policy. Regeneration replaces the generated package assets using the preserved source sheets. `validation.json` lists verified dimensions, alpha/safe-zone checks, ICO frames and file hashes. Validation checks resource references but is not an Android build or device-rendering test.

Copies of both scripts are also included under `source/` for the standalone ZIP. From the extracted package directory, run them with explicit paths:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File source/export_app_icons.ps1 -OutputDirectory .
powershell -NoProfile -ExecutionPolicy Bypass -File source/validate_app_icons.ps1 -IconDirectory .
```

Platform references: [Microsoft Windows icon construction](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction), [Android adaptive icons](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive?hl=en), [Android notification icon guidance](https://android.googlesource.com/platform/frameworks/base/+/9c8685b714b38c2bbf09077b9cba73a95b734269/docs/html/design/style/iconography.jd).
