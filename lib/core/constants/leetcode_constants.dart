import 'package:flutter/material.dart';
import 'package:voyager/domain/models/enums.dart';

/// LeetCode's own difficulty-tier colors, so badges/rings match what the
/// user sees on the actual site.
const kLeetCodeEasyColor = Color(0xFF00B8A3);
const kLeetCodeMediumColor = Color(0xFFFFC01E);
const kLeetCodeHardColor = Color(0xFFFF375F);

Color colorForLeetCodeDifficulty(LeetCodeDifficulty difficulty) =>
    switch (difficulty) {
      LeetCodeDifficulty.easy => kLeetCodeEasyColor,
      LeetCodeDifficulty.medium => kLeetCodeMediumColor,
      LeetCodeDifficulty.hard => kLeetCodeHardColor,
    };

String labelForLeetCodeDifficulty(LeetCodeDifficulty difficulty) =>
    switch (difficulty) {
      LeetCodeDifficulty.easy => 'Easy',
      LeetCodeDifficulty.medium => 'Medium',
      LeetCodeDifficulty.hard => 'Hard',
    };

/// Languages offered in the Track modal's code-language selector.
const leetCodeCodeLanguages = [
  'python',
  'java',
  'cpp',
  'javascript',
  'typescript',
  'go',
  'rust',
  'csharp',
];

/// Display label for a code-language key. Only `cpp`/`csharp` need
/// reformatting — every other key is already the label shown to the user.
String labelForLeetCodeLanguage(String language) => switch (language) {
  'cpp' => 'C++',
  'csharp' => 'C#',
  _ => language,
};
