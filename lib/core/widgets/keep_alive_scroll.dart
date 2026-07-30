import 'package:flutter/material.dart';

/// Preserves scroll offset when this list is temporarily hidden by shell navigation.
class KeepAliveScrollView extends StatefulWidget {
  const KeepAliveScrollView({
    super.key,
    required this.storageKey,
    required this.children,
    this.padding,
  });

  final PageStorageKey<String> storageKey;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  State<KeepAliveScrollView> createState() => _KeepAliveScrollViewState();
}

class _KeepAliveScrollViewState extends State<KeepAliveScrollView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      key: widget.storageKey,
      padding: widget.padding,
      // Without this, children scrolled far enough off-screen get their
      // RenderObject disposed and rebuilt from scratch once scrolled back
      // into view (SliverChildListDelegate's default keep-alive only
      // applies to descendants that opt in via
      // AutomaticKeepAliveClientMixin, which most of these sections don't).
      // A section whose height depends on async data (a FutureBuilder that
      // re-fetches on rebuild, briefly showing a loading placeholder of a
      // different height than the loaded content) then relayouts with a
      // different height than before, and the scroll offset gets corrected
      // to compensate — which reads as a sudden jump. This list is short
      // (a fixed handful of dev/settings/analytics sections), so keeping
      // every child laid out is cheap and avoids the dispose/recreate cycle
      // entirely.
      cacheExtent: double.infinity,
      children: widget.children,
    );
  }
}

/// Preserves scroll offset for builder-based lists in shell tabs.
class KeepAliveScrollList extends StatefulWidget {
  const KeepAliveScrollList({
    super.key,
    required this.storageKey,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.findChildIndexCallback,
  });

  final PageStorageKey<String> storageKey;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  // Lets a caller whose items are individually keyed (e.g. ValueKey(item.id))
  // tell the framework where a shifted key moved to, so it can reuse that
  // item's existing Element instead of destroying and recreating it — which
  // otherwise happens for every item after an insertion/removal point, even
  // when the item's own widget instance is memoized by the caller.
  final ChildIndexGetter? findChildIndexCallback;

  @override
  State<KeepAliveScrollList> createState() => _KeepAliveScrollListState();
}

class _KeepAliveScrollListState extends State<KeepAliveScrollList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView.custom(
      key: widget.storageKey,
      controller: widget.controller,
      childrenDelegate: SliverChildBuilderDelegate(
        widget.itemBuilder,
        childCount: widget.itemCount,
        findChildIndexCallback: widget.findChildIndexCallback,
      ),
    );
  }
}

/// Preserves scroll offset for arbitrary scrollable shell content.
class KeepAliveSingleChildScrollView extends StatefulWidget {
  const KeepAliveSingleChildScrollView({
    super.key,
    required this.storageKey,
    required this.child,
  });

  final PageStorageKey<String> storageKey;
  final Widget child;

  @override
  State<KeepAliveSingleChildScrollView> createState() =>
      _KeepAliveSingleChildScrollViewState();
}

class _KeepAliveSingleChildScrollViewState
    extends State<KeepAliveSingleChildScrollView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(key: widget.storageKey, child: widget.child);
  }
}

/// Preserves scroll offset for CustomScrollViews in shell tabs.
class KeepAliveCustomScrollView extends StatefulWidget {
  const KeepAliveCustomScrollView({
    super.key,
    required this.storageKey,
    required this.slivers,
    this.controller,
    this.cacheExtent,
  });

  final PageStorageKey<String> storageKey;
  final List<Widget> slivers;
  final ScrollController? controller;
  final double? cacheExtent;

  @override
  State<KeepAliveCustomScrollView> createState() =>
      _KeepAliveCustomScrollViewState();
}

class _KeepAliveCustomScrollViewState extends State<KeepAliveCustomScrollView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CustomScrollView(
      key: widget.storageKey,
      controller: widget.controller,
      cacheExtent: widget.cacheExtent,
      slivers: widget.slivers,
    );
  }
}
