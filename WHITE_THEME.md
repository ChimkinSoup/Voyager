This will be a massive endeavor. Change the whole theme of the app, from a dark theme to a light theme. Do NOT remove the current dark theme implementation, instead add a toggle in settings which lets the user change from a dark theme to a light theme. Here is the light theme description:
**Background:**
- **Color:** A warm off-white or light cream.
- **Texture:** Fine-grained, speckled, and subtle. A matte, flat surface with tiny, evenly distributed light gray dots creating a slightly rough visual paper-like pattern. (Implement via a lightweight noise shader or seamless tiling image).
**Animation (Particle System):**
- **Color:** Specific "Petal color" found in user settings, distinct from the main accent color.
- **Appearance:** Subtle, semi-translucent watercolor rose petals that flutter downwards.
- **Behavior ("Wind"):** Apply a sine-wave-based horizontal drift to simulate wind. The wind should visually group petals by applying the same directional force to all active particles simultaneously. Do not use complex fluid dynamics. These wind bursts should be subtle, and should not be locked to affect the WHOLE screen (As in partial bursts should be possible in only parts of the screen). Implement radial velocity modifiers so that this is possible. Allow for future features to be added (e.g. Clicks causing a wind burst to move petals away from the user's cursor, etc)
- **Customization:** Expose parameters for the user to change max active petals, base fall speed, wind frequency, and wind burst strength.
- **Ending (Stateless):** To maintain strict performance and low battery drain, **do not use a physics collision engine**. When petals reach the bottom 10% of the screen, they should gracefully decelerate, stop their rotation, and fade out to zero opacity over 2 seconds. Do not calculate petal-to-petal collisions.
**UI Integration:**
- Invert the contrast for the light theme. Primary text and icons should be a rich, dark slate.
- Update all text boxes, buttons, and custom containers. Ensure any drop shadows are incredibly faint (e.g., 3-5% opacity with a large blur radius) so the UI continues to look flat, matte, and integrated into the textured background.