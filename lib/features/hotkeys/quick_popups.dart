import 'package:flutter/material.dart';
import 'package:voyager/features/journal/journal_page.dart';
import 'package:voyager/features/todo/todo_page.dart';

class QuickJournalPopup extends StatelessWidget {
  const QuickJournalPopup({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      child: SizedBox(width: 480, height: 360, child: JournalPage()),
    );
  }
}

class QuickTodoPopup extends StatelessWidget {
  const QuickTodoPopup({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      child: SizedBox(width: 420, height: 480, child: TodoPage()),
    );
  }
}
