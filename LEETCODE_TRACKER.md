## LeetCode Tracker
### Page Architecture & Layout
- The LeetCode page will be divided into two primary modes: Dashboard (For tracking and stats) and Review Deck (For flashcards)
#### Dashboard
- This is the default view. It is designed to be highly visual
	- Progress Rings (Top Section)
		- Layout: A row of four circular charts
		- The main ring (Total): A hollow circle on the left. In the center it displays [solved] / [total leetcode problems] (e.g. 72 / 3102)
		- This ring will be the main accent color, and the ring itself should contain a small gradiant
	- Difficulty Rings: Three slightly smaller rings to the right for Easy, Medium and Hard. The progress bar fills up based on the total available problems in that tier. 
		- Each ring should be the same respective color as that difficulty in LeetCode
	- Recent Completions & Tag Matrix (Bottom Section)
		- Left column (70% width): A chronological feed of recent completions, each row showing the problem title, difficulty and standard/custom tags. If the user clicks on a specific problem they should be able to see it in detailed view.
		- Right column (40% width): A tag matrix, which is a visually dense cluster of the existing tag pills showing the distribution of solved problems
#### Tracking Flow
- When the user clicks on a pinned "Track" button, the system attempts a public API fetch
	- A sleek, non-intrusive loading toast appears at the top of the screen and a popup appears. It contains the Problem name and ID (Pre-filled if API fetched correctly, but user is always able to manually adjust), tagging (Pre-filled with official LeetCode topics and the user can also append their own), Algorithm (short text box for user to expand on their core approach), time & space complexity (Two small text boxes side by side for the complexity), an explanation (large, multi-line text box for human-readable logic), code block (A dedicated syntax-highlighting text box where the user is able to copy paste their code. Note that this code should not be able to be compiled directly by the app, so it is just text with special syntax highlighting), and notes (small text box for the user's reference in the future)
#### Review Deck
- The Review Deck is a workbench over every tracked problem, built to match the Study page's Deck Workbench. It is not a slideshow — the full-size card lives inside a session.
	- Header: a count line, "N problems · M due". With a filter active it reads "N problems of T · M due", because every count follows the filter rather than the whole library.
	- Directly below it, two glass action buttons: Study (SRS) and Cram. Study is unavailable when nothing is due; Cram ignores the schedule and is available whenever the grid is non-empty.
	- Control bar: a keyword search, three difficulty pills (tap to narrow, tap again to clear), and a tag filter popover. A problem must carry *every* selected tag to survive. No import button — problems come from the Track flow — and no multi-select or reverse, which a deck of one-sided problems has no use for.
	- The rest of the page is a scrollable grid of mini flashcards, ordered least-mastered first. Each tile flips on tap, is ringed in its SRS mastery color (grey new → amber learning → blue → green), badges its difficulty, and counts down the days until its next review on the front face only.
		- Search matches both faces; a problem matched only on its back starts turned around, and the match is marked wherever it lands. Code and notes are out of scope for the search, since neither face shows them.
		- Right-clicking a tile offers Open details…, Edit…, Open on LeetCode, Copy code, Reset progress, and Delete.
	- Study and Cram both inherit exactly what the grid was showing, so a filtered deck drills the filtered set.
#### Review Sessions
- Study mode is the study page's SRS session applied to problems: the full-size flashcard, a New/Learning/Review counter, Fail/Hard/Good/Easy with each button's resulting interval previewed above it, space to flip, and the user's four configured grading keybinds. Grading persists the problem's interval/ease/due date on the problem itself (there is no separate review log) and a problem graded back to a same-day interval re-queues before the session ends.
- Cram mode is the three-bucket drill: every problem starts in bucket 0, a pass moves it up, a fail drops it to 0, and the session ends when all reach bucket 2. Swipe, arrow keys, or the two arrow buttons. Entirely in-memory — it must never write SRS state.
#### The Flashcard
- The full-size card is what a session shows, and what the mini tiles are miniatures of.
	- The front: Centered in a large, frosted-glass container: The problem ID and Title.
		- Top right corner: Difficulty badge
		- Bottom edge: Associated tags
		- If the user clicks anywhere on the card, it will show an animation of the card flipping to the back
			- This applies but not on the centered text with the problem ID and title, in which case if the user clicks on this then it opens the detailed view of the question.
	- The Back: 
		- The Algorithm, Time/Space Complexity, and Explanation are formatted beautifully.
		- The code snippet and notes are purposely excluded from this view. 
		- At the top left corner it will say the question ID and title. If the user clicks on this then it will open the detailed view of the question.
#### Detailed View
- If the user clicks to view the detailed view of a specific question, play a small camera zoom animation. Once the animation is finished, the UI should reveal the remaining data: The syntax-highlighted code block, notes section, and a URL to the actual LeetCode question. If the user collapses the popup, then the zoom reverses leaving the user exactly where they were before. 

