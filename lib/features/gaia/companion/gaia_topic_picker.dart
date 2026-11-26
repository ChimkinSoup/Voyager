import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

/// What [showGaiaTopicPicker] gives back: a topic by [topicId], a new topic
/// named [newName], or with neither, the top level.
typedef GaiaTopicPick = ({String? topicId, String? newName});

/// The one picker for every "which topic" question (GAIA_SETTINGS_HLD.md
/// §5.4): a search box over [topics] by path ("CS246 › Assignments"), Enter
/// taking the first match. With [topLevel], "Top level" is offered first;
/// with [newUnder], a name that matches no topic offers "New topic: …",
/// under that path ('' for the root). Null when it's closed: Esc, once Vim
/// has no use for it (from Insert, it goes to Normal first).
Future<GaiaTopicPick?> showGaiaTopicPicker(
  BuildContext context, {
  required String title,
  required List<({String id, String path})> topics,
  bool topLevel = false,
  String? newUnder,
}) => showDialog<GaiaTopicPick>(
  context: context,
  builder: (_) => _TopicPicker(
    title: title,
    topics: topics,
    topLevel: topLevel,
    newUnder: newUnder,
  ),
);

class _TopicPicker extends StatefulWidget {
  const _TopicPicker({
    required this.title,
    required this.topics,
    required this.topLevel,
    required this.newUnder,
  });

  final String title;
  final List<({String id, String path})> topics;
  final bool topLevel;
  final String? newUnder;

  @override
  State<_TopicPicker> createState() => _TopicPickerState();
}

/// One row of the picker: what it says and what picking it gives.
typedef _Choice = ({String label, GaiaTopicPick pick});

class _TopicPickerState extends State<_TopicPicker> {
  final _query = TextEditingController();
  late final _focus = FocusNode(
    debugLabel: 'gaia topic picker',
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          VimTextScope.escapeIsSpare(node.context)) {
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
      if (event is! KeyDownEvent ||
          (event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
        return KeyEventResult.ignored;
      }
      final first = _choices().firstOrNull;
      if (first != null) Navigator.of(context).pop(first.pick);
      return KeyEventResult.handled;
    },
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<_Choice> _choices() {
    final query = _query.text.trim();
    final lower = query.toLowerCase();
    final found = [
      for (final topic in widget.topics)
        if (topic.path.toLowerCase().contains(lower)) topic,
    ];
    final exact = widget.topics.any(
      (topic) =>
          topic.path.toLowerCase() == lower ||
          topic.path.split(' › ').last.toLowerCase() == lower,
    );
    final under = widget.newUnder;
    return [
      if (widget.topLevel && (query.isEmpty || 'top level'.contains(lower)))
        (label: 'Top level', pick: (topicId: null, newName: null)),
      for (final topic in found)
        (label: topic.path, pick: (topicId: topic.id, newName: null)),
      if (under != null && query.isNotEmpty && !exact)
        (
          label: 'New topic: ${under.isEmpty ? query : '$under › $query'}',
          pick: (topicId: null, newName: query),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices();
    return Center(
      child: Container(
        width: 400,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        decoration: gaiaFloating(
          Theme.of(context).colorScheme,
          radius: GaiaRadius.panel,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(
                  widget.title,
                  style: GaiaType.row.copyWith(color: GaiaInk.bright),
                ),
              ),
              GaiaTextField(
                controller: _query,
                focusNode: _focus,
                autofocus: true,
                hintText: widget.newUnder == null
                    ? 'Find a topic'
                    : 'Find a topic, or name a new one',
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: choices.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          'No topic matches.',
                          style: GaiaType.row.copyWith(color: GaiaInk.muted),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final (i, choice) in choices.indexed)
                            _PickerRow(
                              label: choice.label,
                              first: i == 0,
                              onTap: () =>
                                  Navigator.of(context).pop(choice.pick),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A choice in the picker: lit under the cursor, and the first, which Enter
/// takes, edged.
class _PickerRow extends StatefulWidget {
  const _PickerRow({
    required this.label,
    required this.first,
    required this.onTap,
  });

  final String label;
  final bool first;
  final VoidCallback onTap;

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(GaiaRadius.row),
          border: Border.all(
            color: widget.first
                ? GaiaInk.hairline
                : GaiaInk.hairline.withValues(alpha: 0),
          ),
        ),
        child: Text(
          widget.label,
          overflow: TextOverflow.ellipsis,
          style: GaiaType.row.copyWith(
            color: _hovered || widget.first ? GaiaInk.bright : GaiaInk.dim,
          ),
        ),
      ),
    ),
  );
}
