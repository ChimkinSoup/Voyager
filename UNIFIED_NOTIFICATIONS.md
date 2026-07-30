I want a unified notification system with a global notification button that toggles a floating popup. Here is the design:
## Icon UI: 
- This icon should live at the bottom of the left navigation bar. Use a standard Phosphor tray icon.
	- State 0 (Empty/Idle): The icon is a standard icon
	- State 1 (Semi-important - e.g., Unfilled statistics, a task due tomorrow): A small statistic solid dot appears at the top right corner of the icon, using a muted color (Desaturated version of the main accent color)
	- State 2 (Important - e.g., Bill due today, Event in 1 hour, task deadline): Dot changes to the vibrant primary accent color. It also has a 500 ms breathing animation (Pulsing).
## Popover Layout
- When the user clicks the icon, the small floating window opens
- Section A: Header and quick actions
	- Top left: A sleek title of "Inbox"
	- Top right: A "Clear All" icon (Sweeping broom icon)
- Section B: Pinned Canvas (User notes)
	- Right below the header, a subtle text box where the user's manual notes/reminders live. Include a faint "Type a quick reminder..." text field. 
- Section C: Unified Feed (System Alerts)
	- Below the notes, render a scrollable list of system-generated items
	- Group them strictly by urgency, not category. A bill due in 2 hours is more important than a task due tonight
	- Iconography over text: Rely on the Phosphor icon library instead of typing out the type of event/task
		- e.g. Dollar sign: "Spotify Subscription - $10.99 today (3 hours)", Calendar: "Dentist Appointment - Aug 2 2:30 PM (1 day)", etc, except the Dollar Sign and Calendar would be icons.
	- At the very bottom include a section for analytics alone. This would display all the information that is currently being displayed now to log statistics, along with a date you can change to change the day the statistic is being entered.
## UX Of Clearing
- If the user hovers their mouse over a specific notification row, a small "X" should appear in the far right edge of that row. When the user clears an item, it should collapse gracefully and the rest of the list slide up (Just like the todo list animation)
## Additional Notes
- In the popup, the user should be able to do things like mark tasks as complete (Which would then reflect in the todo list page), rename/recolor/change events, enter analytics manually, etc. Implement a right click menu where applicable, like to straight up delete an event or task, recolor, or rename it. Although some things, like marking a todo task as done, should be included within the notification (Like it should be {checkmark-fat} "Buy milk" and then have a dot to the right that the user is able to click to mark the task as done. This should also play the same confetti animation as in the todo list right now). 