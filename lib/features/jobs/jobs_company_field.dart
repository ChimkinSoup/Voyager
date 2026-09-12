import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';

/// How many suggestions the list shows at once.
const _maxSuggestions = 8;

/// Vertical breathing room for the single-line fields both jobs forms share —
/// company, role title and application URL. [LabeledTextField]'s own dense
/// padding (8) reads as a slot rather than a box at these widths, so they take
/// this instead; the pills and the notes box keep their own metrics.
const jobsFieldContentPadding = EdgeInsets.symmetric(
  horizontal: 14,
  vertical: 14,
);

/// Company combobox (§5): free text plus a typeahead over the suggestion list,
/// ranked so the companies the user has actually applied to come first.
///
/// The list opens on focus, not only on typing: with nothing typed it offers
/// the most recently used companies, which is the common case of applying
/// somewhere again. With no history there is nothing worth offering, so no
/// list appears at all — see [filterJobCompanies].
///
/// Arrow keys move the highlight and Enter (or Tab) fills the field, the same
/// keyboard contract the `#tag` completions use. The field never blocks a name
/// that is not on the list — the list exists so the user can *find* a company
/// they already use instead of minting a near-duplicate, not to constrain what
/// they can enter.
class JobsCompanyField extends StatefulWidget {
  const JobsCompanyField({
    super.key,
    required this.controller,
    required this.companies,
    required this.onChanged,
    this.onSubmitted,
    this.recentKeys = const [],
    this.categoryColorFor,
    this.accentColor,
    this.autofocus = false,
    this.focusNode,
    this.label = 'Company',
    this.contentPadding,
  });

  final TextEditingController controller;
  final List<JobCompany> companies;
  final ValueChanged<String> onChanged;

  /// Fired on Enter, but only when the completion list is closed — with it
  /// open, Enter belongs to the highlighted suggestion. So the first Enter
  /// fills the field and the second moves on, which is what the two presses
  /// read as.
  final ValueChanged<String>? onSubmitted;

  /// Company keys most-recently-applied-to first, from [jobRecentCompanyKeys].
  /// Decides both the ranking and what an empty query offers.
  final List<String> recentKeys;

  /// Swatch shown beside a categorised suggestion. Null for companies with no
  /// category, which is also what an unset callback means for all of them.
  final Color? Function(JobCompany company)? categoryColorFor;
  final Color? accentColor;
  final bool autofocus;
  final FocusNode? focusNode;
  final String label;

  /// Overrides the dense field's own padding, so the combobox can be given the
  /// same height as the plain fields it sits above.
  final EdgeInsetsGeometry? contentPadding;

  @override
  State<JobsCompanyField> createState() => _JobsCompanyFieldState();
}

class _JobsCompanyFieldState extends State<JobsCompanyField> {
  final _layerLink = LayerLink();
  final _fieldKey = GlobalKey();
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  OverlayEntry? _overlay;
  List<JobCompany> _matches = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _attachFocusNode(widget.focusNode);
  }

  @override
  void didUpdateWidget(JobsCompanyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _detachFocusNode();
      _attachFocusNode(widget.focusNode);
    }
    // The companies or recents changed underneath an open list. Refreshed
    // after the frame, not here: this runs during build, and the refresh
    // rebuilds or inserts the overlay. A closed list stays closed.
    if (_overlay != null &&
        (!listEquals(oldWidget.companies, widget.companies) ||
            !listEquals(oldWidget.recentKeys, widget.recentKeys))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _overlay != null) _refreshMatches();
      });
    }
  }

  void _attachFocusNode(FocusNode? node) {
    _ownsFocusNode = node == null;
    _focusNode = node ?? FocusNode();
    _focusNode.addListener(_handleFocusChanged);
    // Owned here rather than by the caller: the completion list has to see
    // Enter and the arrows before anything above the field does.
    _focusNode.onKeyEvent = _handleKeyEvent;
  }

  void _detachFocusNode() {
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.onKeyEvent = null;
    if (_ownsFocusNode) _focusNode.dispose();
  }

  @override
  void dispose() {
    _removeOverlay();
    _detachFocusNode();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      _refreshMatches();
    } else {
      // One frame of grace: tapping a suggestion moves focus out of the field
      // before the tap resolves, and tearing the overlay down synchronously
      // would cancel the very tap that is choosing a company.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) _removeOverlay();
      });
    }
  }

  void _refreshMatches() {
    final matches = filterJobCompanies(
      widget.companies,
      widget.controller.text,
      recentKeys: widget.recentKeys,
    );
    // An exact match is the one case where the list has nothing left to offer:
    // the only suggestion is the text already in the field.
    final exhausted =
        matches.length == 1 &&
        jobCompanyKey(matches.first.name) ==
            jobCompanyKey(widget.controller.text);
    _matches = exhausted ? const [] : matches.take(_maxSuggestions).toList();
    // The list is rebuilt from scratch on every keystroke, so the highlight
    // returns to the top rather than following whatever moved into its slot.
    _selected = 0;
    if (_matches.isEmpty) {
      _removeOverlay();
    } else if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _showOverlay() {
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 240;
    final accent = widget.accentColor ?? Theme.of(context).colorScheme.primary;
    _overlay = OverlayEntry(
      builder: (context) => Positioned(
        width: width,
        child: CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          // Same tap group as the field's own [EditableText], so clicking a
          // suggestion doesn't read as a tap *outside* the field.
          //
          // [TextField]'s default `onTapOutside` unfocuses on desktop, and it
          // fires on pointer-down — which tore this overlay down a frame
          // before the click's pointer-up could land on it, so a suggestion
          // could only ever be chosen with the keyboard.
          child: TapRegion(
            groupId: EditableText,
            child: _SuggestionList(
              matches: _matches,
              selectedIndex: _selected,
              accentColor: accent,
              categoryColorFor: widget.categoryColorFor,
              onHover: _highlight,
              onSelected: _select,
            ),
          ),
        ),
      ),
    );
    overlayState.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  bool get _isOpen => _overlay != null && _matches.isNotEmpty;

  void _highlight(int index) {
    if (_selected == index) return;
    _selected = index;
    _overlay?.markNeedsBuild();
  }

  void _move(int delta) {
    _highlight((_selected + delta + _matches.length) % _matches.length);
  }

  void _select(JobCompany company) {
    widget.controller.text = company.name;
    widget.controller.selection = TextSelection.collapsed(
      offset: company.name.length,
    );
    widget.onChanged(company.name);
    _removeOverlay();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isOpen || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    // Ctrl/Cmd+Enter bubbles on to the form's submit scope with the name as
    // typed, the same as it does past the tag popup.
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.tab) &&
        !isSubmitChord(event)) {
      _select(_matches[_selected]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      // Claimed rather than bubbled: with the list up, Escape means "close
      // this", and letting it through would close the sheet the field is in.
      _removeOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: LabeledTextField(
        key: _fieldKey,
        label: widget.label,
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        accentColor: widget.accentColor,
        dense: true,
        contentPadding: widget.contentPadding,
        onSubmitted: widget.onSubmitted,
        onChanged: (value) {
          widget.onChanged(value);
          _refreshMatches();
        },
      ),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.matches,
    required this.selectedIndex,
    required this.accentColor,
    required this.categoryColorFor,
    required this.onHover,
    required this.onSelected,
  });

  final List<JobCompany> matches;
  final int selectedIndex;
  final Color accentColor;
  final Color? Function(JobCompany company)? categoryColorFor;
  final ValueChanged<int> onHover;
  final ValueChanged<JobCompany> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: VoyagerScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < matches.length; i++)
                  MouseRegion(
                    onEnter: (_) => onHover(i),
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => onSelected(matches[i]),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        color: i == selectedIndex
                            ? accentColor.withValues(alpha: 0.16)
                            : Colors.transparent,
                        child: Row(
                          children: [
                            if (categoryColorFor?.call(matches[i])
                                case final color?)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                matches[i].name,
                                style: theme.textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
