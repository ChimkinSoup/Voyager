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

class _KeepAliveScrollViewState extends State<KeepAliveScrollView> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      key: widget.storageKey,
      padding: widget.padding,
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
  });

  final PageStorageKey<String> storageKey;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<KeepAliveScrollList> createState() => _KeepAliveScrollListState();
}

class _KeepAliveScrollListState extends State<KeepAliveScrollList> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView.builder(
      key: widget.storageKey,
      itemCount: widget.itemCount,
      itemBuilder: widget.itemBuilder,
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
  State<KeepAliveSingleChildScrollView> createState() => _KeepAliveSingleChildScrollViewState();
}

class _KeepAliveSingleChildScrollViewState extends State<KeepAliveSingleChildScrollView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      key: widget.storageKey,
      child: widget.child,
    );
  }
}
