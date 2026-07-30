# Dream Journal
## Global Theme & Visual Identity
- This page will feel like a specialized, tranquil page, maintaining the core design system while introducing a distinct, dreamy atmosphere
	- Canvas: The same warm off-white/light cream background with the subtle, lightweight paper texture.
	- The falling cherry blossom petals will remain active
	- On the desktop view, a soft, partially transparent watercolor cherry blossom tree branch will sweep in from the top right corner or the far right edge of the screen
		- Ensure the tree has a low opacity so it doesn't distract the user's text legibility
## Split-Pane Dashboard
- Utilize a standard 35/65 split-plane layout. Note that this split-plane layout should be adjustable to some extend (Like how in the journal page you are able to change the width of the left bar). If the user changes the location of the bar, it should persist it across saves (Just like how the journal behaves now)
	- Left column (35%): A clean, chronological scroll of past dreams.
		- The card will contain the date, dream title, and the first couple of bits of text in the dream description
		- If the user hasn't written a detailed log yet, the card should have a faint border or subtle indicator letting them know it's drafted
	- Right column (65%): The active reading and writing space. It features a completely borderless, zen-mode environment heavily utilizing custom layout math
## Dream Editor & Collapsible Scratchpad UX
- Here is the interaction pipeline:
	- A clean large title text box at the very top
	- There should be a square that resembles a sticky note that is half sticking out of the bottom right corner (You should just be able to see a sliver of it). Once the user clicks on it, it should animate out, to take up the bottom right corner of the screen. There the user is able to take brief notes on their dreams, just to jog their memory later on. Also there should be a button that "pins" it to the screen, which in that case the sticky note should animate so it disappears completely (So it slides back into the corner of the screen at an arc like usual, but it continues so it's completely hidden), then a text box should slide out from beneath the screen while also decreasing the size of the main dream body text box. This way the user is able to see both the notes and the main text box. There should be a button to unpin the notes section, which would then play out the animation but in reverse.
	- The main detailed log should take up most of the vertical height (Unless the user pins the notes), and it should use existing tag logic so the user can tag specific dreams.
## Analytics
- Add a toggle in settings to let the user decide if they want to see their dream statistics in the analytics page
    - If toggled on, add a fourth statistic to the analytics page at the top that is just a boolean of if the user has entered a dream or not on a certain day. 