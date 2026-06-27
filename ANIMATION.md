To eliminate the frame-by-frame rebuilds of your main task list and keep Voyager running at a strict 60fps, we will replace the implicit layout animation with an explicit `AnimationController` driving an `AnimatedBuilder`.

Here is the Low-Level Design (LLD) and exact code replacements to isolate the panel's render box.

### 1. State Mixin & Controller Initialization

Update your `_TodoPageState` definition to include the `SingleTickerProviderStateMixin` and initialize the explicit controller.

```dart
class _TodoPageState extends ConsumerState<TodoPage> with SingleTickerProviderStateMixin {
  late final AnimationController _panelController;
  late final Animation<double> _panelAnimation;

  @override
  void initState() {
    super.initState();
    _panelController = AnimationController(
      vsync: this,
      duration: _todoEditPanelDuration,
    );
    
    _panelAnimation = CurvedAnimation(
      parent: _panelController,
      curve: Curves.easeOutCubic,
    );

    // Replaces the brittle _editPanelCloseTimer
    _panelController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        setState(() {
          _editPanelTask = null;
          _selectedTaskId = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _panelController.dispose();
    super.dispose();
  }
  // ... existing state variables

```

### 2. Update the Triggers

Remove `_editPanelOpen` and the manual timer logic from your trigger methods. Let the controller handle the open/close state.

```dart
void _openEditPanel(TodoTask task) {
  setState(() {
    _editPanelTask = task;
    _selectedTaskId = task.id;
  });
  _panelController.forward();
}

void _closeEditPanel() {
  // Safe to call even if already closing/closed
  _panelController.reverse(); 
}

```

### 3. Widget Tree Injection (`build` method)

In your `build` method, locate the `ClipRect` near the bottom of the `Row`. Replace the `AnimatedAlign` with an `AnimatedBuilder`.

The critical optimization here is the `child` parameter of the `AnimatedBuilder`. We pass the heavily nested `TodoEditPanel` into the `child` parameter so it is strictly built **once** when opened, and the builder only recalculates the `Align`'s `widthFactor` on every frame.

**Replace your existing `ClipRect` block (lines 752-814) with this:**

```dart
              ClipRect(
                child: AnimatedBuilder(
                  animation: _panelAnimation,
                  builder: (context, child) {
                    return Align(
                      alignment: Alignment.centerRight,
                      widthFactor: _panelAnimation.value,
                      child: child,
                    );
                  },
                  // The 'child' is cached by the AnimatedBuilder during the animation ticks.
                  // It will not rebuild the TodoEditPanel itself unless the outer build() runs.
                  child: SizedBox(
                    width: _todoEditPanelWidth,
                    child: panelTask == null
                        ? const SizedBox.shrink()
                        : TodoEditPanel(
                            key: ValueKey(panelTask.id),
                            task: panelTask,
                            listColor: _listColorFor(panelTask.listId, lists),
                            lists: lists,
                            onClose: () {
                              _invalidateTodoListData(listId: panelTask.listId);
                              _closeEditPanel();
                            },
                            onChanged: () {
                              _invalidateTodoListData(listId: panelTask.listId);
                            },
                            onDeleted: () {
                              _invalidateTodoListData(listId: panelTask.listId);
                              _closeEditPanel();
                            },
                            onToggleStar: () => _toggleStar(
                              panelTask,
                              sorted.where((t) => !t.completed).toList(),
                            ),
                            onTaskOptimistic: (task) {
                              _taskOverrides[task.id] = task;
                              final affectsSort =
                                  task.dueDate != panelTask.dueDate ||
                                  task.starred != panelTask.starred ||
                                  task.sortOrder != panelTask.sortOrder ||
                                  task.listId != panelTask.listId;
                              if (affectsSort || task.listId != _selectedListId) {
                                final movedList = task.listId != _selectedListId;
                                setState(() {
                                  _editPanelTask = task;
                                  if (movedList) {
                                    _selectedListId = task.listId;
                                    _selectedTaskId = task.id;
                                  }
                                });
                                if (movedList) {
                                  _markListViewed(task.listId);
                                }
                              }
                            },
                          ),
                  ),
                ),
              ),

```