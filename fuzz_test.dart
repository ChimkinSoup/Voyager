import 'lib/domain/services/fractional_index.dart';
import 'dart:math';

void main() {
  var r = Random(42);
  var indices = [FractionalIndex.first()];
  for (int i = 0; i < 5000; i++) {
    int op = r.nextInt(3);
    if (indices.isEmpty || op == 0) {
      indices.add(FractionalIndex.after(indices.last));
    } else if (op == 1) {
      int idx = r.nextInt(indices.length);
      indices.insert(idx, FractionalIndex.before(indices[idx]));
    } else {
      int idx = r.nextInt(indices.length - 1);
      indices.insert(idx + 1, FractionalIndex.between(before: indices[idx], after: indices[idx + 1]));
    }
  }
  
  var sorted = List<String>.from(indices)..sort();
  for (int i = 0; i < indices.length; i++) {
    if (indices[i] != sorted[i]) {
      print('Sort mismatch at $i: ${indices[i]} vs ${sorted[i]}');
      return;
    }
  }
  print('Fuzz test passed!');
}
