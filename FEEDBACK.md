# FEEDBACK
Here is some feedback, implement fixes in the best way you see fit. If there is any unclarity, ask questions before proceeding. If the change is applicable to other parts of the app (Such as a universal change like changing a textbox or a repeated UI), apply the change to wherever necessary. If there are contradictory requests, ask before implementing.
## Journal
- [ ] When the user toggles off the mood bar, the body text box shifts slightly upwards, can you stop this from happening?
- [ ] If the user is viewing a journal, then creates another journal, they are left viewing the same entry from the old journal even when they have entered their new journal. Instead make this behavior identical to if the user exits out of the new journal and enters it again (So create a new empty journal entry and show that instead when the user switches to their newly created journal)
## Todo
- [ ] Remove the "Image" text above the image gallery and the "Subtask" text above the subtask list
- [ ] 
## Search
- [ ] If the user clicks "Close" when editing a journal entry can you instead make it discard all changes the user made in the search page? 
## Calendar
- [ ] Can you save the last calendar that was viewed and open that up automatically (This includes view all calendars)?
- [x] If the user enters all calendar views, then the calendar dropdown menu should also switch
- [ ] If the user clicks on a recurring event, then the small press-down animation plays out for every single recurring event, can you make it just the one they clicked on?
## LeetCode
- [ ] Can you remove the background that appears if the user selects multiple solutions when editing a question (Like the background that appears that separates each solution from each other)
- [ ] If the user adds multiple solutions to a question, then can you make the "solution x" text that states the question's number be in the main accent color instead of being black? 
- [ ] Add just a little bit of padding between the "Solution X" text and the algorithm text box when the user enters multiple solutions
- [ ] When the user presses the "Strip" button above a code text box, currently it only gets rid of comments. But can you also make it check the very last line (Only the last line) of the code text box and if it is a newline (Completely empty newline) then delete that too? This should happen for all languages
- [ ] If I open up the statistics and scroll down to the calendar view, then whenever the user's cursor hovers over a square it displays an informative popup next to user's cursor. Except if I scroll down a bit, then hover very close to the top of the calendar near the cutoff where it displays the year, the informative popup is covered by this header, instead of properly flipping and showing it below the cursor instead of above, fix this
## Finance
- [ ] If I hover over a transaction in the ledger page, while also scrolling down a little so that half of the transaction row is hidden underneath the top of the scrollable area (Like half of it is hidden under the Ledger/Analytics/Goal area), then the grey hitbox that appears from hovering over the transaction still appears on top of the Ledger/Analytics/Goal area, fix this
## Job Tracker
- [ ] The "Clear" button next to the search bar is not a proper glass button. Same thing with the "Open" button under the application URL
- [ ] If  the user copies their linked profiles to their clipboard, make the confirmation a toast notification instead the bar at the bottom of the page. Additionally make the buttons for copying the user's linked profiles larger
- [ ] Move the application date capsule from where it is right now to next to the "History" text at the bottom, aligned to the right. Then replace the application date capsule with the season capsule so that the status and season capsules both take up half of the horizontal width of the editor
- [ ] Make the search text bar slightly taller
## Settings
- [ ] If the user tries to add Job application profiles, the cancel and save buttons are not proper glass buttons
## Miscellaneous
- [ ] When the user right clicks a word and then chooses to add it as a snippet, the popup has a "Manage all snippets" button, but it is not a proper glass button, fix this