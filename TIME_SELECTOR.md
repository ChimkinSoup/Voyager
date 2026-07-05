### 1. The Container (The Anchored Popover)

Instead of a screen-dimming modal dialog that takes over the whole app, this will be an **OverlayEntry** (or an anchored dropdown) that floats directly below or above the Time Pill the user just tapped.

* **Visual Style:** A sleek, rounded rectangle (e.g., `BorderRadius.circular(12)`).
* **Background:** Uses your dark scaffold base (`#1B1B22`) but slightly elevated. Add a very subtle, colored shadow (using the user's chosen accent color at 10-15% opacity) so it "pops" off the geometric background without needing a harsh border.
* **Size:** Compact. Roughly 200px wide and 250px tall. It should feel like a contextual menu, not a new page.

### 2. The Internal Layout (Start Time Popup)

When the user clicks the **Start Time Pill**, the popover reveals a purely vertical layout with two distinct zones:

**Zone A: The Smart Input (Top)**

* **Visuals:** A seamless, borderless text field sitting at the very top of the popover. It has a subtle underline or background tint to indicate it is active.
* **Interaction:** The *millisecond* this popover opens, the app must automatically request keyboard focus on this text field.
* **The Magic:** The user can instantly type "2p", "1400", or "2:30 PM". As they type, the list below instantly filters to match their input. Pressing `Enter` commits the time and closes the popup.

**Zone B: The Scrollable Wheel (Bottom)**

* **Visuals:** Below the text input is a standard, highly polished `ListView`.
* **Data:** It generates a list of times in 15-minute increments (e.g., 12:00 PM, 12:15 PM, 12:30 PM...).
* **Highlighting:** The currently selected time (or the closest time based on what they are typing in Zone A) is highlighted with the user's accent color (perhaps using that "Negative Space Pill" design we discussed for your navigation icons, where the background of the active time becomes dark/accented and the text becomes stark white).
* **Interaction:** The user can seamlessly grab the scrollbar (or swipe on mobile) to find their time and click it, which immediately closes the popup.

### 3. The Internal Layout (End Time / Duration Popup)

When the user clicks the **End Time Pill**, the popover uses the exact same container, but the internal layout shifts to prioritize *Duration*, because humans schedule by duration.

**Zone A: The Duration Grid (Top)**

* **Visuals:** A sleek `Wrap` or `GridView` of compact chips.
* **Data:** Chips say `15m`, `30m`, `1h`, `1.5h`, `2h`, `All Day`.
* **Interaction:** Clicking one of these chips calculates the exact end time based on the Start Time, sets it, and instantly closes the popup. This is a 1-click interaction for 90% of events.

**Zone B: The Custom End Time (Bottom)**

* **Visuals:** A divider separates the quick-duration chips from a scrollable list exactly like the Start Time popup.
* **Interaction:** If they have a weird meeting that ends at exactly 3:45 PM, they just ignore the chips and scroll down to click `3:45 PM`, or they type it into the smart input at the top.

### The Execution Summary

1. User taps the pre-filled Start Time Pill (`10:00 AM`).
2. The sleek popover snaps into existence right below the pill.
3. The user's keyboard is already active.
4. They press "1", "1", "a", then "Enter" (for 11:00 AM).
5. The popover instantly vanishes, and the Start Time Pill updates to `11:00 AM`.
6. (Optional Auto-Flow): The app could automatically open the *End Time* popover right after the Start Time is set, leaving them staring at the "1h" duration chip. They hit `Enter` again, and the time configuration is flawlessly completed in under 2 seconds.
