# FEEDBACK
Here is some feedback, implement fixes in the best way you see fit. If there is any unclarity, ask questions before proceeding. If the change is applicable to other parts of the app (Such as a universal change like changing a textbox or a repeated UI), apply the change to wherever necessary. If there are contradictory requests, ask before implementing.
## Journal 
- [x] If the user tries to use arrow keys to move around in the color selection menu (When editing the color of a journal), their first arrow key input causes the current selection to jump back to the first color, then they are able to move normally. Instead make the pointer start from the currently selected color.
- [x] Make the "new entry" button the same shade as the journal 
## Todo List
- [x] If the user views all tasks, then opens the todo list dropdown menu, and selects a specific journal, it should be opened and "All tasks" should be untoggled
- [x] If the user toggles all tasks then views the dropdown menu to select a specific list there is still the last seen list bordered as if it is currently selected, remove this
- [x] If the user toggles all tasks the "Add" button to add a new task remains the last viewed list's accent color when it should be the same color as the all tasks list (Which is just the main accent color)
- [x] If the user tries to use arrow keys to move around in the color selection menu (When editing the color of a todo list), their first arrow key input causes the current selection to jump back to the first color, then they are able to move normally. Instead make the pointer start from the currently selected color.
## Search
- [x] Currently if the user is editing the title of a journal entry, then presses enter, their focus is shifted to the entry body. Instead, make it so that pressing enter, either when editing the title OR the body, then the popup is closed and the edit is saved
## Calendar
- [x] When making a new event entry in the calendar, the user is automatically focused on the title text box. If the user presses tab, they should then become focused on the notes text box, then if they press tab again, it should be focused on the "All day" icon. If they press enter when focused on the all day icon it should toggle to be off. Currently the order is like title-> time selector -> notes, but by default the time selector does not appear so I want to change this behavior.
- [x] Currently in the monthly calendar the current week is highlighted by the calendar color, but can you make the current day be highlighted with a slightly higher opacity than the rest of the week, so the current day stands out more?
## Analytics 
- [x] If the user tries to add a new tracker that has no name, it cannot be created but no error message pops up. Make user that red text that says the title cannot empty shows up BELOW the title text box
- [x] When the user hovers over a heatmap statistic, the informative popup appears but it is hidden beneath the background rectangles (Like the hover rectangle that shows you are hovering over a specific statistic or the starred region that indicates starred statistics), ensure the informative popup appears above them (Like make it a little bit more opaque so it is easier to read the text of the popup)
- [x] If the user hovers over interpolated values in a sparkline it does not show the interpolated value, instead it shows the value that the user has entered (This only happens sometimes, like for some curves it will show the interpolated value but for some it will show half interpolated, half the closest exact value the user has entered, and some just an exact value the user has entered, even though the graph shows that the value is obviously changing since it is being interpolated)
- [x] If a sparkline shows a very sharp jump between a very high value and a very low value (Like 0), then the graph has a small dip BELOW 0. I want this fixed so the graph never goes below the min or above the max. 
- [x] Thin text boxes appear to be broken. Like when inputting an integer value as the default value for a new statistic, or entering the title of a new statistic. The border has little rectangles on the left and right side that stick out, and also the text boxes are in general too thin. Find and fix all of these everywhere they are present
## Settings
- [x] When i try to reorder the nav pages, instead of keeping the "hitbox" for the draggable space only the icon, make it the whole, option (including the text and the nav icon too)
## Dream Journal
- [x] Add the date and trash icon to a dream journal
- [x] Add right click menu so that when the user right clicks on a specific dream journal on the left bar it will give them the option to see statistics or to delete it
- [ ] Add dreams as a statistic in the analytics page so for every dream journal it will be a boolean that is shown as an additional statistic (skipped — withdrawn)
- [x] Change the hint text of the title to "Title" and make it like the journal title text box, so if the user clicks on the text box then the hint text should move to the top of the text box
- [x] Make the dream notes icon a different shade so it doesn't blend into the text box
- [x] Move the "Add" button to the bottom of the left bar and instead add text that says "New dream" just like the journal page
- [x] Remove the option to pin the notes to the bottom of the screen entirely. 
## Life Tracker
- [x] Shorten nav page name to "Life" instead of "Life Tracker"
- [x] Widen the bucket list popup
- [x] Allow the user to edit their bucket list items that have already been added
- [x] Give a sum of all bucket list items and how many are complete in the popup too
- [x] Currently if the user starts with an empty bucket list and then adds one item, since the "nothing here yet" text disappears and is replaced by the first item, the height of the bucket list popup actually shortens. I want it to stay consistent so just change the height of the "nothing here yet" to be equal to the height of ONE bucket list item
## LeetCode Tracker
- [x] Reduce the padding between the top of the "Track a problem" popup UI and the actual start of the popup (Like the edge of the popup and the text that says "Track a problem" and the X button, I want that gap decreased)