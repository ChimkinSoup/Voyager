# GlassButton

`GlassButton` is a modular, reusable Flutter widget located in [`lib/core/widgets/glass_button.dart`](file:///c:/Users/Juno/Code/Voyager/lib/core/widgets/glass_button.dart). It implements a glassmorphic aesthetic featuring background blur, 3D specular gradient edge highlights, glossy top reflections, dynamic hover/tap micro-animations, and full theme integration.

---

## Key Features

- **Glassmorphic Surface**: Combines `BackdropFilter` with `ImageFilter.blur` and a multi-stop translucent fill gradient.
- **Specular 3D Border**: Custom edge painter (`_GlassBorderPainter`) that renders light highlights on top-left edges and subtle shadows on bottom-right edges.
- **Top Gloss Reflection**: Highlights the upper edge with a light-washing reflection overlay.
- **Micro-Animations**: Responds smoothly to user interaction with scale compression (`0.96x` on press) and dynamic opacity/shadow shifts on hover.
- **Resizeable & Responsive**: Supports fixed or content-based dimensions (`width`, `height`, `padding`, `margin`, `borderRadius`, `dense`) with internal `FittedBox` scaling to prevent overflow.
- **Recolorable**: Easily tinted via `color`, `textColor`, `iconColor`, and `borderColor`, while falling back intelligently to `VoyagerColors` and the current app theme.

---

## API Reference

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `onPressed` | `VoidCallback?` | `null` | Callback triggered on button tap. If `null` or `enabled: false`, button is disabled. |
| `label` | `String?` | `null` | Text displayed inside the button. |
| `icon` | `Widget?` | `null` | Leading icon widget. |
| `trailingIcon` | `Widget?` | `null` | Trailing icon widget. |
| `child` | `Widget?` | `null` | Custom child widget. Overrides `label`, `icon`, and `trailingIcon`. |
| `color` | `Color?` | `theme.colorScheme.primary` | Base tint color for the glass surface. |
| `textColor` | `Color?` | Auto-derived | Text label color. |
| `iconColor` | `Color?` | Auto-derived | Icon color. |
| `borderColor` | `Color?` | Auto-derived | Glass edge highlight color. |
| `width` | `double?` | `null` | Explicit width. If `null`, fits content + padding. |
| `height` | `double?` | `null` | Explicit height. If `null`, fits content + padding. |
| `padding` | `EdgeInsetsGeometry?` | `16h, 10v` (`10h, 6v` if dense) | Padding inside the glass surface. |
| `margin` | `EdgeInsetsGeometry?` | `null` | Outer margin around the button. |
| `borderRadius` | `BorderRadius?` | `12.0` (`10.0` if dense) | Border radius of the glass container. |
| `blurSigma` | `double` | `12.0` | Backdrop blur intensity (`sigmaX` and `sigmaY`). |
| `glassOpacity` | `double` | `0.06` | Base opacity of the glass fill gradient. |
| `borderOpacity` | `double` | `0.22` | Base opacity of the specular border. |
| `elevation` | `double` | `1.5` | Drop shadow depth multiplier. |
| `enabled` | `bool` | `true` | Whether the button is interactive. |
| `dense` | `bool` | `false` | Compact sizing for toolbars and app bars. |
| `tooltip` | `String?` | `null` | Optional hover tooltip. |

---

## Usage Examples

### 1. Basic Icon + Text Button (Toolbar / App Header)
```dart
GlassButton(
  onPressed: () => print('Syncing...'),
  label: 'Sync Google',
  icon: const Icon(PhosphorIconsRegular.arrowClockwise),
  dense: true,
)
```

### 2. Custom Size & Recolor (Primary Action)
```dart
GlassButton(
  onPressed: () => print('Saved!'),
  label: 'Save Changes',
  icon: const Icon(Icons.check),
  color: Colors.purple,
  width: 200,
  height: 48,
  borderRadius: BorderRadius.circular(16),
)
```

### 3. Icon-Only Glass Button
```dart
GlassButton(
  onPressed: () => print('Settings opened'),
  icon: const Icon(Icons.settings),
  dense: true,
)
```

---

## File Locations

- **Widget Definition**: [`lib/core/widgets/glass_button.dart`](file:///c:/Users/Juno/Code/Voyager/lib/core/widgets/glass_button.dart)
- **Unit Tests**: [`test/glass_button_test.dart`](file:///c:/Users/Juno/Code/Voyager/test/glass_button_test.dart)
- **Usage in App**: [`lib/features/calendar/calendar_page.dart`](file:///c:/Users/Juno/Code/Voyager/lib/features/calendar/calendar_page.dart)
