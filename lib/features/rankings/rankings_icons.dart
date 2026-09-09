import 'package:flutter/widgets.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// The icons a ranking category can wear, by stable key.
///
/// Categories store the *key*, never the code point: the icon package is free
/// to renumber its font between versions, and a stored code point would then
/// quietly become a different picture — or a blank box — on every device that
/// upgraded.
const rankingCategoryIcons = <String, IconData>{
  'star': PhosphorIconsRegular.star,
  'television': PhosphorIconsRegular.television,
  'filmSlate': PhosphorIconsRegular.filmSlate,
  'popcorn': PhosphorIconsRegular.popcorn,
  'forkKnife': PhosphorIconsRegular.forkKnife,
  'pizza': PhosphorIconsRegular.pizza,
  'hamburger': PhosphorIconsRegular.hamburger,
  'coffee': PhosphorIconsRegular.coffee,
  'wine': PhosphorIconsRegular.wine,
  'bookOpen': PhosphorIconsRegular.bookOpen,
  'gameController': PhosphorIconsRegular.gameController,
  'musicNotes': PhosphorIconsRegular.musicNotes,
  'mapPin': PhosphorIconsRegular.mapPin,
  'airplaneTilt': PhosphorIconsRegular.airplaneTilt,
  'mountains': PhosphorIconsRegular.mountains,
  'camera': PhosphorIconsRegular.camera,
  'paintBrush': PhosphorIconsRegular.paintBrush,
  'trophy': PhosphorIconsRegular.trophy,
  'heart': PhosphorIconsRegular.heart,
  'globe': PhosphorIconsRegular.globe,
  'cube': PhosphorIconsRegular.cube,
  'confetti': PhosphorIconsRegular.confetti,
};

/// The icon for a stored key, falling back to the star a category is created
/// with so an unknown key from a newer build still draws something.
IconData rankingCategoryIcon(String key) =>
    rankingCategoryIcons[key] ?? PhosphorIconsRegular.star;
