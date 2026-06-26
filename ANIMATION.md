1. Move Event Metrics to the Global Cache (CPU Fix)
The Issue: During the Month → Year morph, MorphDayEventStack calculates its frozen metrics (bar height, stride, text size) for all 42 cells on the very first frame of the animation. This causes a tiny CPU spike right when the animation needs to start smoothly.
The Fix: Event bar height, stride, and font sizes are identical across all cells and determined purely by the screen area size. Move these calculations into CalendarLayoutCache.compute(). Read them globally during the morph instead of calculating them 42 times on frame 1.

2. Flatten the Inactive Rows (GPU Fix)
The Issue: In the Month ↔ Week morph, you fade out the 5 inactive rows using an Opacity layer over a MonthDayGrid. Fading 35 individual cells (each with text, borders, and events) is expensive.
The Fix: Wrap the inactive MonthDayGrid in a RepaintBoundary. This forces the graphics processor to take a single snapshot of the 5 rows and simply fade that single flat image to zero, drastically reducing render times.

3. Remove the Redundant Reverse Warmup (Memory Fix)
The Issue: You have a GPU warmup at login (which covers morphReverse=true) and a second reverse GPU warmup when the month view first opens.
The Fix: Delete the second warmup. Shader compilation is resolution-independent. Because your login warmup already compiled the instructions for the inverted lerps and reverse styles, doing it again at "real size" does nothing but waste layout processing power. The login warmup is sufficient.

4. Zero-Allocation Matrix Updates (Memory Fix)
The Issue: Inside _MorphAnimationLayer, _applyYearTransform(t) interpolates 16 floats. If this creates a new Matrix4 object every frame, it will trigger the garbage collector during the 600ms flight.
The Fix: Ensure you instantiate a single final Matrix4 _yearTransform = Matrix4.zero(); in your initState. During the animation tick, use _yearTransform.setValues(...) to update the numbers in place. Passing this single mutated object to the Transform widget ensures zero memory allocation during the animation.