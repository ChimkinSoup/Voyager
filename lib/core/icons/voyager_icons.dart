import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Canonical Phosphor icons used across Voyager.
///
/// Prefer these over referencing [PhosphorIconsRegular] / [PhosphorIconsBold]
/// directly so nav and feature UI stay consistent when icons change.
abstract final class VoyagerIcons {
  VoyagerIcons._();

  /// Journal section and journal-related UI.
  static const IconData journal = PhosphorIconsRegular.notebook;

  /// Calendar nav, date pickers, and due-date controls.
  static const IconData calendar = PhosphorIconsRegular.calendarDots;

  /// Search section.
  static const IconData search = PhosphorIconsBold.magnifyingGlass;

  /// Dev / debug section.
  static const IconData debug = PhosphorIconsRegular.bugBeetle;

  /// Manage journals, to-do lists, and similar list settings.
  static const IconData manage = PhosphorIconsRegular.fadersHorizontal;
}
