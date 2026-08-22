import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';

/// Company combobox (§5): free text plus a case-insensitive contains
/// typeahead over the suggestion list.
///
/// The field never blocks a name that is not on the list — the list exists so
/// the user can *find* `Visa Inc.` when they type `visa` instead of minting a
/// near-duplicate, not to constrain what they can enter.
class JobsCompanyField extends StatefulWidget {
  const JobsCompanyField({
    super.key,
    required this.controller,
    required this.companies,
    required this.onChanged,
    this.categoryColorFor,
    this.accentColor,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final List<JobCompany> companies;
  final ValueChanged<String> onChanged;

  /// Swatch shown beside a categorised suggestion. Null for companies with no
  /// category, which is also what an unset callback means for all of them.
  final Color? Function(JobCompany company)? categoryColorFor;
  final Color? accentColor;
  final bool autofocus;

  @override
  State<JobsCompanyField> createState() => _JobsCompanyFieldState();
}

class _JobsCompanyFieldState extends State<JobsCompanyField> {
  final _layerLink = LayerLink();
  final _fieldKey = GlobalKey();
  late final FocusNode _focusNode;
  OverlayEntry? _overlay;
  List<JobCompany> _matches = const [];

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
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
    );
    // An exact match is the one case where the list has nothing left to offer:
    // the only suggestion is the text already in the field.
    final exhausted =
        matches.length == 1 &&
        jobCompanyKey(matches.first.name) ==
            jobCompanyKey(widget.controller.text);
    _matches = exhausted ? const [] : matches.take(8).toList();
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
    _overlay = OverlayEntry(
      builder: (context) => Positioned(
        width: width,
        child: CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          child: _SuggestionList(
            matches: _matches,
            categoryColorFor: widget.categoryColorFor,
            onSelected: _select,
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

  void _select(JobCompany company) {
    widget.controller.text = company.name;
    widget.controller.selection = TextSelection.collapsed(
      offset: company.name.length,
    );
    widget.onChanged(company.name);
    _removeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: LabeledTextField(
        key: _fieldKey,
        label: 'Company',
        controller: widget.controller,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        accentColor: widget.accentColor,
        dense: true,
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
    required this.categoryColorFor,
    required this.onSelected,
  });

  final List<JobCompany> matches;
  final Color? Function(JobCompany company)? categoryColorFor;
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
                for (final company in matches)
                  InkWell(
                    onTap: () => onSelected(company),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          if (categoryColorFor?.call(company) case final color?)
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
                              company.name,
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
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
