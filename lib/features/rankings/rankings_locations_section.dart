import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_location_dialog.dart';
import 'package:voyager/features/rankings/rankings_location_preview.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// The editor panel's Locations section: the entry's places in their saved
/// order, and the way to add one.
///
/// Every write goes through [RankingsActions] by id rather than through the
/// panel's own save, so it lands on the entry as stored — a branch another
/// device added a moment ago is not this section's to drop. None of them
/// promotes a queued entry: pinning a place you want to try is not starting
/// it.
class RankingLocationsSection extends ConsumerWidget {
  const RankingLocationsSection({
    super.key,
    required this.parent,
    required this.accent,
    required this.mapShowing,
    this.onShowOnMap,
    this.readOnly = false,
  });

  final RankingParent parent;
  final Color accent;

  /// Whether a map is open beside the panel, which is where a typed place
  /// name is then searched around.
  final bool mapShowing;

  /// Opens the map on a location, from a press on the preview in list view.
  final ValueChanged<RankingLocation>? onShowOnMap;
  final bool readOnly;

  /// Where a search starts: the open map's centre, else the entry's first
  /// location, else wherever the map was last left in this run of the app,
  /// else where the device was last found.
  LatLng? _near(WidgetRef ref) {
    final viewport = ref.read(rankingMapViewportProvider);
    final last = viewport == null
        ? null
        : LatLng(viewport.latitude, viewport.longitude);
    if (mapShowing && last != null) return last;
    final first = parent.locations.firstOrNull;
    if (first != null) return LatLng(first.latitude, first.longitude);
    return last ?? ref.read(rankingDeviceLocationProvider);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final actions = RankingsActions.detached(
      ProviderScope.containerOf(context, listen: false),
    );
    final pick = await showRankingLocationDialog(
      context,
      accent: accent,
      near: _near(ref),
      existing: parent.locations,
    );
    if (pick == null) return;
    await actions.addLocation(
      parent.id,
      latitude: pick.latitude,
      longitude: pick.longitude,
      address: pick.address,
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    RankingLocation location,
  ) async {
    final actions = RankingsActions.detached(
      ProviderScope.containerOf(context, listen: false),
    );
    final pick = await editRankingLocation(
      context,
      accent: accent,
      location: location,
      siblings: parent.locations,
    );
    if (pick != null) await actions.updateLocation(parent.id, pick);
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    RankingLocation location,
  ) async {
    final actions = RankingsActions.detached(
      ProviderScope.containerOf(context, listen: false),
    );
    final label = await showPromptNameDialog(
      context,
      title: 'Rename location',
      initial: location.label,
      label: 'Label',
    );
    if (label == null) return;
    await actions.updateLocation(
      parent.id,
      location.copyWith(label: label.trim()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final locations = parent.locations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (locations.isNotEmpty &&
            ref.watch(geoapifyClientProvider) != null) ...[
          RankingLocationPreview(
            parent: parent,
            accent: accent,
            // Beside an open map, a press pans it there, as a row's does.
            onTap: mapShowing
                ? (location) =>
                      ref.read(rankingMapFocusProvider.notifier).state =
                          location
                : onShowOnMap,
          ),
          const SizedBox(height: 8),
        ],
        if (locations.isNotEmpty)
          // Nested in the panel's scroll view — see [ScrollOffsetIsolate].
          ScrollOffsetIsolate(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: locations.length,
              onReorderItem: (oldIndex, newIndex) {
                final ids = [for (final location in locations) location.id];
                ids.insert(newIndex, ids.removeAt(oldIndex));
                RankingsActions(ref).reorderLocations(parent.id, ids);
              },
              itemBuilder: (context, index) {
                final location = locations[index];
                return _LocationRow(
                  key: ValueKey(location.id),
                  index: index,
                  location: location,
                  readOnly: readOnly,
                  // Only with a map to pan: a request left standing in
                  // list view would make the same row's next click, with the
                  // map open, look like no change.
                  onTap: () {
                    if (!mapShowing) return;
                    ref.read(rankingMapFocusProvider.notifier).state = location;
                  },
                  menuItems: () => [
                    ContextMenuItem(
                      label: 'Rename',
                      icon: PhosphorIconsRegular.pencilSimple,
                      onTap: () => _rename(context, ref, location),
                    ),
                    ContextMenuItem(
                      label: 'Edit location…',
                      icon: PhosphorIconsRegular.mapPin,
                      onTap: () => _edit(context, ref, location),
                    ),
                    ContextMenuItem(
                      label: 'Remove',
                      icon: PhosphorIconsRegular.trash,
                      isDestructive: true,
                      onTap: () => removeRankingLocationWithUndo(
                        context,
                        ref,
                        parentId: parent.id,
                        location: location,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        if (!readOnly) ...[
          if (locations.isNotEmpty) const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              dense: true,
              icon: const Icon(PhosphorIconsRegular.mapPinPlus, size: 13),
              label: 'Add location',
              onPressed: () => _add(context, ref),
            ),
          ),
        ] else if (locations.isEmpty)
          Text(
            'No locations',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Opens the location dialog on [location] and returns it moved, or null when
/// the dialog was cancelled. [siblings] are the entry's locations, which the
/// moved one may not land on top of.
Future<RankingLocation?> editRankingLocation(
  BuildContext context, {
  required Color accent,
  required RankingLocation location,
  required List<RankingLocation> siblings,
}) async {
  final point = LatLng(location.latitude, location.longitude);
  final pick = await showRankingLocationDialog(
    context,
    accent: accent,
    heading: 'Edit location',
    submitLabel: 'Save',
    initialPoint: point,
    initialAddress: location.address,
    near: point,
    existing: [
      for (final sibling in siblings)
        if (sibling.id != location.id) sibling,
    ],
  );
  if (pick == null) return null;
  return location.copyWith(
    latitude: pick.latitude,
    longitude: pick.longitude,
    address: pick.address,
  );
}

class _LocationRow extends StatefulWidget {
  const _LocationRow({
    super.key,
    required this.index,
    required this.location,
    required this.readOnly,
    required this.onTap,
    required this.menuItems,
  });

  final int index;
  final RankingLocation location;
  final bool readOnly;
  final VoidCallback onTap;
  final ValueGetter<List<ContextMenuItem>> menuItems;

  @override
  State<_LocationRow> createState() => _LocationRowState();
}

class _LocationRowState extends State<_LocationRow> {
  /// So the row's ⋯ button opens the very menu a right-click does.
  final _menuKey = GlobalKey<ContextMenuRegionState>();

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final readOnly = widget.readOnly;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // The address is the display name when there is no label, so it is only a
    // second line under one.
    final secondary = location.label.isNotEmpty && location.address.isNotEmpty
        ? location.address
        : null;

    final row = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              if (!readOnly)
                ReorderableDragStartListener(
                  index: widget.index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      PhosphorIconsRegular.dotsSixVertical,
                      size: 14,
                      color: muted.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      location.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (secondary != null)
                      Text(
                        secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (!readOnly)
                Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: 'Location options',
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(PhosphorIconsRegular.dotsThree),
                    onPressed: () {
                      final box = buttonContext.findRenderObject() as RenderBox;
                      _menuKey.currentState?.openMenuAt(
                        box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return readOnly
        ? row
        : ContextMenuRegion(
            key: _menuKey,
            itemsBuilder: widget.menuItems,
            child: row,
          );
  }
}
