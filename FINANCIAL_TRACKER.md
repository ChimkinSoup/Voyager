This will be a large endeavor. Make a new nav page that will be a financial tracker. Here are the features I want included in the tracker:
1. Daily Ledger
	- User is able to log a transaction (Expenses and Deposits)
	- User should be able to assign tags (e.g., #groceries, #travel, #paycheck, etc) to group expenses/deposits. They can also add a brief text note (e.g., "Dinner with friends") to remember exactly what the purchase was
	- Should provide a transaction history, which is a clean chronological feed of recent transactions, grouped by day or week, showing the money flowing in (Green) and out (Main accent color)
2. Subscription & Bill Radar
	- This is a dedicated space to manage subscriptions or reoccurring bills
	- There should be an active subscription roster, which is a list of all recurring costs
		- There should be a toggle, that when enabled, will take all periodic bills and calculates what the user pays per year (Ex. a $15/month subscription is calculated to be $180 per year), and this will be shown in faint greyed out text next to the subscription. This toggle should be located in the settings page.
	- Will show upcoming deadlines in a timeline, showing which bills are due in chronological order with the days left until they are due exactly.
3. Dynamic Budgeting & Pacing
	- User can define tag-based limits to set a soft-limit on a specific tag (e.g. "Keep #dining_out under $200 this month")
	- Pacing visuals: A progress bar that shows how much of the budget is spent relative to the time left in the month
4. Macro Analytics & Cash Flow
	- Allow the user to create categories, to group multiple tags into one (e.g. A "Eating out" category which includes #mcdonalds and #burger_king)
	- This is the analytical suite where the user reviews their financial health over time.
	- Income Vs Expense Dashboard: A high level chart (Weekly, monthly, yearly) comparing total money earned versus total money spent
	- Spending Breakdown: A visual breakdown (Like a pie chart or categorized bar chart) showing how much spending has gone to each tag/category
	- Net Worth/ Total balance tracker: A macroscopic graph showing the user's total accumulated wealth over time. This should allow the user to track assets too, such as investments or physical assets.
5. Financial Goals & Milestones
	- Savings bucket: The user can create specific goals (e.g. "Japan trip", "New laptop", "Emergency fund", etc) with a target dollar amount
	- Progress Rings: As the user logs income and allocates it to these buckets, geometric progress rings will up
This will be the UI:
- The "Hero" section (Top of the screen)
	- There will be a large elegant display of the current month's "Net Flow" (Income minus Expenses) or Total Balance
	- Right next to this number, use a minimalistic line graph (No axes, no gridlines, just a smooth curve) drawn in the main accent color that shows the trajectory of your spending over the last 30 days
- Place a floating action button in the bottom right. Clicking this button will NOT navigate you to a new page, but instead triggers an animated modal. 
Implementation Constraints & Architecture:
- UI Components: Do not use default Material UI text fields or date pickers. All text inputs must be wrapped in the custom `VoyagerNotchedContainer`. All date selections must reuse the custom Scrolling Wheel Selectors.
- Layout: For desktop/tablet screens, implement a split dashboard layout. The Daily Ledger should take the left 60% of the width, and the Radar/Insights should stack vertically on the right 40%.
- Tagging: Re-use the existing tags SQLite table (UUID, name, hex color) built for the journal entries. Do not create a separate tagging engine.
- Sync & Database: All transactions must follow the existing offline-first architecture. Save instantly to local SQLite, utilize the existing CRDT pipeline for syncing, and implement tombstoning for any deleted transactions.
If you have any questions or concerns about the implementation details, ask for clarification before starting your implementation.