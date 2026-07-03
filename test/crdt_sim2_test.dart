import 'package:voyager/domain/services/character_op_session.dart';
import 'package:voyager/domain/services/character_sequence_crdt_merger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CRDT test 3 - TWO SESSIONS', () {
    final registry1 = CharacterOpRegistry();
    final session1 = registry1.ensureSession(
      collection: 'journal_entries',
      documentId: '1',
      clientId: 'deviceA', // Same device!
      initialText: '',
    );
    session1.recordTextChange('', 'Test is from the journal page');
    final ops1 = session1.takePendingOps(); // logicalClock 0..28
    
    // Simulate user closing and re-opening JournalPage!
    // It creates a new session seeded from the current text.
    final registry2 = CharacterOpRegistry();
    final session2 = registry2.ensureSession(
      collection: 'journal_entries',
      documentId: '1',
      clientId: 'deviceA', // Same device!
      initialText: 'Test is from the journal page',
    );
    // logicalClock 0..28 generated for the SEED!
    
    // User types "this is from the search page"
    session2.recordTextChange('Test is from the journal page', 'this is from the search page');
    final ops2 = session2.takePendingOps(); 
    // This generates deletes for "Test" with logicalClock 0, 1, 2, 3!
    // AND inserts for "this" with logicalClock 29, 30, 31, 32!
    
    // Now simulate syncing!
    // First, sync server gets ops1.
    // Then sync server gets ops2.
    // applyMergedPayload processes them.
    
    // Test the ORIGINAL BUGGY logic
    final byIdBuggy = <String, CharacterOperation>{};
    for (final op in [...ops1, ...ops2]) {
      final existing = byIdBuggy[op.id];
      if (existing != null) {
        bool wins = false;
        if (op.deleted != existing.deleted) {
           wins = op.logicalClock >= existing.logicalClock;
        } else if (op.logicalClock != existing.logicalClock) {
           wins = op.logicalClock > existing.logicalClock;
        } else {
           wins = op.clientId.compareTo(existing.clientId) > 0;
        }
        if (wins) byIdBuggy[op.id] = op;
      } else {
        byIdBuggy[op.id] = op;
      }
    }
    
    final merger = CharacterSequenceCrdtMerger();
    final liveBuggy = byIdBuggy.values.where((op) => !op.deleted).toList()
      ..sort((a, b) {
        final pos = a.position.compareTo(b.position);
        if (pos != 0) return pos;
        final clock = a.logicalClock.compareTo(b.logicalClock);
        if (clock != 0) return clock;
        return a.clientId.compareTo(b.clientId);
      });
      
    final buggyText = liveBuggy.map((op) => op.character).join();
    print('BUGGY TEXT: ' + buggyText);
    
    // Now test the REAL logic in merger (which we just fixed!)
    final charOps = merger.mergeOperations([], []); // Dummy to test actual merger logic? No, let's just pass SyncOps.
    // wait, we can just call mergeOperations on the raw CharacterOperations? 
    // No, mergeOperations takes SyncOperations. But we can mock it by just using _wins:
    // Actually, we JUST FIXED CharacterSequenceCrdtMerger! 
    // So let's see if the fixed logic works!
    
    final byIdFixed = <String, CharacterOperation>{};
    for (final op in [...ops1, ...ops2]) {
      final existing = byIdFixed[op.id];
      if (existing != null) {
        // THIS IS THE FIXED LOGIC:
        bool wins = false;
        if (op.deleted != existing.deleted) {
           wins = op.deleted;
        } else if (op.logicalClock != existing.logicalClock) {
           wins = op.logicalClock > existing.logicalClock;
        } else {
           wins = op.clientId.compareTo(existing.clientId) > 0;
        }
        if (wins) byIdFixed[op.id] = op;
      } else {
        byIdFixed[op.id] = op;
      }
    }
    
    final liveFixed = byIdFixed.values.where((op) => !op.deleted).toList()
      ..sort((a, b) {
        final pos = a.position.compareTo(b.position);
        if (pos != 0) return pos;
        final clock = a.logicalClock.compareTo(b.logicalClock);
        if (clock != 0) return clock;
        return a.clientId.compareTo(b.clientId);
      });
      
    final fixedText = liveFixed.map((op) => op.character).join();
    print('FIXED TEXT: ' + fixedText);
  });
}
