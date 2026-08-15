## Workout Tracker
### Planner View
- At the top of the screen, place a segmented toggle pill to toggle between a 7-day Week and custom split
	- In the weekly view, there should be a standard 7-column layout (Sun-Sat or Mon-Sun depending on the user selecting "Start week on Monday" which should be a toggle in the settings page)
	- In the custom split view the UI should become a horizontally scrolling timeline of Day 1, 2, 3, .... 
- Users can drag their modular exercises (like a Bench press card) from a persistent panel directly onto the days.
### Active Workout
- Reuse the scrolling wheel so the user does not have to manually type in weight and reps. Instead there should be two side-by-side scrolling wheels (Left is weight and right is reps) and the user can fluidly flick the wheels. The number of sets will still be manually typed in however
- The scrolling wheel will default to what the template planned out, but the user can still scroll up or down manually, depending on if they are tired or not. This changes the text to the main accent color to give a visual distinction that this is not the planned amount
- When the active workout view is collapsed, there should be an animation of the whole screen minimizing into a minimalistic floating bar. It will be a sleek, pill-shaped notch where on the left side, an icon indicating a live workout will live in the main accent color, the center will contain the current exercise, with reps and sets in the format (Bench Press • 8|3) for 3 sets, 8 reps each (Also add weight in here). If the user is resting and has set a rest timer, the border of the entire pill will act as a subtle progress bar that slowly drains as the time ticks down, and there will be a live countdown in the pill as text
- If the user taps on the floating island, it will expand downward from the top putting the user back into active workout mode
- The user should be able to mark each set as complete, which then saves their weight and number of reps for that specific set
- The floating island should persist, regardless of what page the user is navigating to
### Detailed Exercise View
- Tapping on any specific exercise from anywhere on the app triggers a camera zoom animation, expanding it into a dedicated analytics page for that specific movement. 
	- There will be a header, followed by a sparkline. The sparkline will strictly track the weight achieved in each session (Per set). If the user manually adjusts their weight for one set during a workout, that will be reflected here too
	- Below the sparkline will be a 30-day volume heatmap, which is a horizontal row of 30 rounded squares and each square represents one day where the user performed this specific exercise (So it is not strictly the last 30 days, just the last 30 days where the user has performed the exercise). The opacity/brightness of the square's accent color will correlate to the total volume (Weights * reps * sets)
	- At the bottom of the page there will be a text box where the user can type out form cues
### Global Voyager Integrations
- In settings, a toggle allows workouts to appear on the main calendar page. Just display a small icon at the top of the day (Next to the date numbering on the monthly calendar or next to the bottom date in the weekly calendar, not present at all in the yearly calendar).
- Also in settings should be a toggle to add a statistic in the analytics page, where a simple boolean tracker is used to track the days that the user has done a workout (This is a daily boolean and every time the user does a workout it should be true, else it defaults to false)
## Miscellaneous
- These are features that I specifically want. If they are not mentioned in the above plan, they should still be implemented. If you have any questions regarding these points then ask before starting your implementation
- Allow the user to switch between weekly based workout plans (Like Mon -> Sun) and period based (Like 4 day splits so they repeat every 4 days regardless of the weekday)
- Reuse the scrolling wheel for picking numbers
- Allow the option for a rest timer between sets but by default they should be off (As in they are by default not turned on)
- Give the user the option of turning on workout view in calendar mode
- Specific exercises should be modular, so you can drag and drop them into different workouts, but every single bench press set is tied back to the "Bench press" exercise. You should be able to view each exercise specifically, this should include a notes section (Where you can give yourself pointers on how to perform the exercise), weights, and reps. There should also be a sparkline that tracks the weight you perform every time you do that exercise. For now base the sparkline only off of weight, not of the reps you do. 
- During a workout, you should be able to live change a workout to be more or less than what you planned on it being, this should show as a hiccup in your exercise (Since if you now view that exercise in detailed view you will see a drop), but this is a temporary weight change and thus next time that workout repeats you will be back to your original weight. You can also do this but moving up in weight
- There should be a toggle in settings that adds a workout tracker which is a boolean to the analytics page
- For every exercise there should also be a volume tracker that shows a heatmap of the daily volume for the past 30 days that an exercise has been done (This doesn't necessarily mean 30 days exactly, it means 30 days of doing that exercise so for a 4 day workout split where you do this exercise on day 1 and not on 2, 3, 4, then it would really be over 120 days)
