import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps a typed clock time well-formed as it is entered: digits group into
/// `h:mm`, a stray `a`/`p` becomes `AM`/`PM`, and out-of-range values are
/// refused. Deletion is shaped to match: backspacing the `M` of "8:00 PM"
/// takes the whole meridiem with it, and backspacing a `:` takes the digit
/// before it, so one press undoes one thing the user actually typed.
class TimeTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;

    String workingText = newValue.text.toUpperCase();
    bool isDeletion = oldValue.text.length > newValue.text.length;

    if (isDeletion) {
      String oldUpper = oldValue.text.toUpperCase();
      if (oldUpper.endsWith('AM') || oldUpper.endsWith('PM')) {
        // If they deleted the 'M', strip the remaining 'A' or 'P' and spaces
        if (workingText.endsWith('A') || workingText.endsWith('P')) {
          workingText = workingText.replaceAll(RegExp(r'[AP ]+$'), '');
        }
      }

      bool isSingleCharBackspace =
          (oldValue.text.length - newValue.text.length == 1) &&
          oldValue.selection.isCollapsed;
      if (isSingleCharBackspace) {
        int oldOffset = oldValue.selection.baseOffset;
        if (oldOffset > 0 && oldOffset <= oldValue.text.length) {
          if (oldValue.text[oldOffset - 1] == ':') {
            int newOffset = newValue.selection.baseOffset;
            if (newOffset > 0 && newOffset <= workingText.length) {
              workingText =
                  workingText.substring(0, newOffset - 1) +
                  workingText.substring(newOffset);
            }
          }
        }
      }
    }

    String text = workingText.replaceAll(RegExp(r'[^0-9:AMP ]'), '');
    text = text.replaceFirst(RegExp(r'^[^0-9]+'), '');
    text = text.replaceAll(RegExp(r' +'), ' ');
    text = text.replaceAll(RegExp(r':+'), ':');

    String timePart = text.replaceAll(RegExp(r'[AMP ]'), '');
    String letters = text.replaceAll(RegExp(r'[^APM]'), '');
    if (letters.isNotEmpty) {
      if (letters.startsWith('A'))
        letters = 'AM';
      else if (letters.startsWith('P'))
        letters = 'PM';
      else
        letters = '';
    }

    if (!text.contains(':') && timePart.length >= 3) {
      if (timePart.length == 3) {
        timePart = '${timePart.substring(0, 1)}:${timePart.substring(1)}';
      } else if (timePart.length >= 4) {
        timePart = timePart.substring(0, 4);
        timePart = '${timePart.substring(0, 2)}:${timePart.substring(2)}';
      }
    } else if (text.contains(':')) {
      timePart = text.replaceAll(RegExp(r'[AMP ]'), '');
      List<String> parts = timePart.split(':');
      if (parts.length > 2) parts = parts.sublist(0, 2);

      String before = parts[0];
      String after = parts.length > 1 ? parts[1] : '';

      if (before.length > 2) before = before.substring(0, 2);
      if (after.length > 2) after = after.substring(0, 2);

      timePart = '$before:${after}';
      if (text.endsWith(':') && after.isEmpty) {
        // preserve trailing colon
      } else if (after.isEmpty && !text.contains(':')) {
        timePart = before;
      }
    }

    List<String> parts = timePart.split(':');
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      int? h = int.tryParse(parts[0]);
      if (h != null) {
        if (h > 23 && !timePart.contains(':') && timePart.length == 2) {
          timePart = '${timePart.substring(0, 1)}:${timePart.substring(1)}';
          parts = timePart.split(':');
          h = int.tryParse(parts[0]);
        }
        if (h != null && h > 23) return oldValue;
      }
    }

    if (parts.length > 1 && parts[1].isNotEmpty) {
      if (parts[1].length == 1) {
        int? m1 = int.tryParse(parts[1]);
        if (m1 != null && m1 > 5) {
          parts[1] = '0$m1';
          timePart = '${parts[0]}:${parts[1]}';
        }
      }
      int? m = int.tryParse(parts[1]);
      if (m != null && m > 59) return oldValue;
    }

    String finalText = timePart;
    if (letters.isNotEmpty) {
      finalText += ' $letters';
    }

    if (text.endsWith(' ') && letters.isEmpty) {
      finalText += ' ';
    }
    if (text.endsWith(':') && !finalText.contains(':')) {
      finalText += ':';
    }

    int newOffset = newValue.selection.baseOffset;
    if (finalText != newValue.text) {
      if (oldValue.text.length > newValue.text.length) {
        newOffset = newValue.selection.baseOffset;
        if (newOffset > finalText.length) newOffset = finalText.length;
      } else {
        newOffset = finalText.length;
      }
    }

    return TextEditingValue(
      text: finalText,
      selection: TextSelection.collapsed(
        offset: newOffset.clamp(0, finalText.length),
      ),
    );
  }
}

/// Puts the whole time under the cursor, so the next keystroke replaces it
/// rather than appending to a value the user never meant to keep.
void selectAllTimeText(TextEditingController controller) {
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );
}
