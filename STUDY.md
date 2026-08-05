## Studying Page
### Global Study Hub
- When you navigate to the study page you are greeted with a full-screen centered dashboard. 
	- At the very top, centered, display global statistics (Cards pending review today, cards reviewed today, cards reviewed total)
	- Below the statistics there should be a library grid made up of elevated cards in a responsive grid. When you click on a folder, it expands inline to reveal specific decks or folders inside of it. 
		- Folders (Categories): e.g. Math, Biology. Clicking a folder smoothly expands it to reveal the files inside. Note that folders can contain folders.
		- Files (Decks): e.g. Midterm 1, Derivatives. These are indented slightly. There cannot be files within files.
	- A floating button in the bottom right allows the user to quickly create a new folder or new deck. 
- When you click on a specific deck, the deck container will scale up and zoom forward to consume the entire screen. The Global Hud fades away behind it and the Deck Workbench UI fades in. You are now "inside" the deck
### Deck Workbench
- This is the administrative dashboard for a single, specific set of cards. It takes up 100% of the screen
	- Header: Back navigation. A clean "< Library" button in the top left to zoom back out
		- Additionally contains the path of the current deck (Ex. math / calc / midterm)
	- Title and stats of the deck should be at the top (Stats include total cards and number of cards due for review)
	- Directly below the title, there are two glass action buttons. One to start reviewing (By default with SRS) and one for cram mode
	- Control Bar: A sleek row of utility icons right above the card list:
		- Search (Keyword filter), import JSON, and a multi-select toggle. Right aligned is a "Add card" button
	- The remaining 70% of the screen is a scrollable list of every card in the desk. Each row shows a preview of the front, and if you click it a small animation plays that shows the back of the card. This animation only plays out for the specific card in the preview deck. On each card (Regardless of whether the front or back of the card is showing) will be a small dot whose color represents its SRS mastery
### Multi-Select and Batch Actions
- Selection Mode: Tapping the multi-select toggle (Or long pressing on a card) reveals checkboxes on every preview card. Clicking one selects it. The user is still able to click on the preview card (But not the checkmark) to check the other side of the card.
	- Floating context bar: When cards are selected, a pill-shaped toolbar floats up from the bottom center. It displays "X cards selected" alongside Move, Duplicate, and Delete.
	- Clicking Move opens a clean, focused modal showing the library overview. You select the target deck, hit confirm, and the selected cards instantly slide out of the current view. 
### Study Session
- Clicking a study session triggers a zoom transition, hiding the card roster and administrative buttons entirely, leaving a distraction free screen containing just the active flashcard and the grading buttons.
- When the user taps the card (Or presses space), the same animation plays out that is currently used for the flashcards for Leetcode questions. The user is able to then mark the card for SRS
- If the user enters in cram mode, use buckets 
### Nested Folders
This should override any details about folders mentioned above (If they are contradicting)
#### 1. How It Should Be Done (In-Memory Stack)

- **The State:** Create a simple Riverpod state that holds a `List<String>` of folder UUIDs. This is your "Breadcrumb Stack."
- **The Logic:** * When the user opens the Study page, the stack is empty (showing the Root).
    - Clicking a folder pushes its UUID onto the list. The UI instantly queries SQLite for items where `parent_folder_id == current_uuid`.
    - Clicking "Back" pops the last UUID off the list.
#### 2. How the UI Should Be Adjusted
- **The Breadcrumb Header:** Replace the static `< Library` back button with a horizontally scrollable row of text pills (e.g., `Root / Math / Calculus`).
- **The Transition:** Tapping a specific breadcrumb (like `Math`) chops the Riverpod stack down to that exact UUID and triggers a reverse "Zoom Out" animation.
- **The Move Modal:** Change the move popup to a cascading list. Tapping a folder doesn't open it; it just slides the next level of folders into view alongside it, with a floating "Move Here" button.
#### 3. The Edge Cases You Must Account For
- **The Cycle Failsafe (The Infinite Loop):** Before executing a Move, the database must recursively check the target folder's parents. If the target folder is a child (or grandchild) of the folder being moved, the action must be blocked immediately.
- **The Ghost Parent (Orphaned Folders):** If you delete "Folder A" on your phone, but "Folder B" (which is inside A) is simultaneously updated on your laptop, the CRDT sync might leave Folder B looking for a parent that no longer exists. _Fix:_ Your SQLite query must automatically render any orphaned folders (where the parent ID is missing) at the Root level so you don't lose data.
- **Animation Clipping:** If a user rapidly taps a breadcrumb to jump back 3 levels while a 500ms zoom animation is already playing, you need to ensure the `AnimationController` resets cleanly rather than attempting to overlap rendering and dropping frames.
### Cramming Mode
- Places all cards into temporary buckets during the session. 
	- Bucket 0: Unseen/failed. All cards start here
	- Bucket 1: Familiar. If you pass a card in bucket 0, it moves here
	- Bucket 2: Mastered. If you pass a card in bucket 1, it moves here and is "graduated" from the active session.
- Loop: The algorithm prioritizes pulling the next active card from the lowest available bucket. If you fail a card in bucket 1 (Or even bucket 2), it drops all the way down to bucket 0. The session only ends when every single card reaches bucket 2
- Because these are temporary buckets, it must NOT update the SRS metadata and it should run entirely in-memory
- The user should be able to use their arrow keys to move left and right (Right is successful, left is failed). Additionally they should be able to drag the card to the left or right and have a small animation play where the card shrinks and disappears and the next card animates in. There should also just be left and right arrow buttons the user can press.
- At the top of the full-screen canvas, there is a segmented progress bar divided into three colors representing the size of the buckets. You will get immediate visual feedback after swiping through cards
### SRS
- The core mechanism relies on a simple equation to calculate the days until you see the card again: $I _{new} = I _{old} \times E$ (Where I is the interval in days and E is the card's specific ease factor).
- Baseline: Every card starts with an ease factor of 2.5 and interval of 0
- Grading matrix: When you reveal a card, you grade your memory. Your grade alters both the interval and ease factor permanently
	- Fail: The interval resets to 0 (You see it again today). The ease factor drops (e.g. -0.2)
	- Hard: The interval grows slightly. The ease factor drops slightly (e.g. -0.15)
	- Good: the interval multiplies normally by the current Ease factor. The ease factor is unchanged
	- Easy: The interval multiplies aggressively. The ease factor increases (+0.15)
- There should be a segmented row of stylized buttons at the bottom of the card that say Fail, Hard, Good, and Easy. 
	- Directly below each grading button dynamically render the text of what the $I _{new}$ will be before the user clicks it (e.g. Above fail it says "< 1m", above good it says "4d", etc)
- At the top of the canvas display a minimalist counter showing "New / Learning / Review".
### Additional Notes
- The creation text box should be able to take in latex. This doesn't mean LIVE latex, so like if I type in $_{0}$ it shouldn't immediately show a subtext 0, but when the user sees the flashcard with that text it should be changed to latex. This should be easier to implement as it is not live but just a rendering. 
- In settings the user should also be able to add 4 keybinds that they can use to quickly swap in SRS mode. For example e for easy, f for fail, h for hard, and g for good. So they don't have to use their mouse. Note that in ANY mode they should still be able to press space to flip the card