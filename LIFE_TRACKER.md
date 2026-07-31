## Unified Canvas
- There will be a watercolor tree sitting dead center of the screen, it's roots anchored at the bottom edge of the screen and it's canopy sprawling outward to near the top and side edges.
- There will be 4160 standard leaves, representing 4160 weeks in 80 years. Additionally on the tree there will be a handful of blossoms, which will be a distinct assets that are clearly not regular leaves. Blossoms will be the main accent color (Somewhat faint though), and the leaves will be randomly generated leaves following the leaf coloring described in the settings page. Make the leaves also sway from side to side as if there is wind.
- On the right side of the tree there should be a swing that is hanging off a branch, slowly swinging forward and backwards. This swing should just be two simple ropes and a plank of wood, where you can see that the rope has been strung through two holes in the plank and knotted below. In the swing will be a bubble.
### Blossoms
- Colors will be faint versions of the main accent color so they remain distinct from the colors of the falling leaves in the background and on the tree itself. 
- Scatter them strategically across the canopy, some near the edges and some near the center (At uniform randomness)
- When the user clicks a blossom, the blossom should subtly scale up and a tooltip should animate from the blossom (Expanding outwards like it came from the blossom). Animate leaves around the popup as if the popup generated a gust of wind that makes the leaves still on the tree shudder.
- Blossoms will display various statistics, these should be the statistics:
	- Weeks remaining
	- Heartbeats taken
	- Time slept sleeping
	- Tasks conquered (Total tasks over all todo lists)
	- Lifetime mood (Overall happiness that will the average of every mood entry the user has made)
	- Miles travelled around the sun
	- Full moons experienced
- Ensure that the statistics are optimized and they do not pull data live (Especially tasks conquered and lifetime mood, since the rest are purely mathematical you can compute those live if that would be easier). 
- When the user hovers over a blossom, the blossom should enlarge to show it is currently in focus, and faint small text underneath should appear describing what statistic is being shown (Make this 1 word, at most 2, so very brief)
### Swing And Bubble
- Hanging from a thick lower-right branch is a simple rope swing. Resting in the center of the seat is a single ethereal bubble. When the user hovers over the bubble it should gently expand and increase its glow slightly. 
### Bucket List Popup
- If the user clicks on the bubble it should also animate a popup (Just like the blossoms), except this popup will be larger than the blossom popups. It will function exactly like todo lists but with hollow circles for completions. Additionally each "task" will lack some regular task features like a due date or subtasks (And anything else you think necessary). When the user does finally mark off a task, they will then have the option of writing a note for that specific task that can provide background information on them completing that bucket list task. 
### Opening Animation
- Once per app restart, the first time the user opens this page, the tree should first initially appear with all of it's leaves intact, then suddenly X number of leaves should (evenly spread out across the tree) fall for the X weeks that the user has lived. They should fall and collect on the floor. These leaves should NOT fade out and instead remain on the floor. If the user changes pages and comes back, these same leaves should still be on the ground (Without ever running an animation unless the app is restarted). 
- Keep the background animation of the leaves falling as normal.