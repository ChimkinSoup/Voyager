import 'lib/domain/services/fractional_index.dart';

void main() {
  var prev = FractionalIndex.first();
  var indices = [prev];
  for (int i = 0; i < 100; i++) {
    prev = FractionalIndex.after(prev);
    indices.add(prev);
  }
  
  var sortedIndices = List<String>.from(indices)..sort();
  for (int i = 0; i < indices.length; i++) {
    if (indices[i] != sortedIndices[i]) {
      print('Sort mismatch at $i: ${indices[i]} vs ${sortedIndices[i]}');
      return;
    }
  }
  print('after() generates perfectly sorted indices.');

  // Let's test between() generating a lot of indices between two bounds
  var a = FractionalIndex.first();
  var b = FractionalIndex.after(a);
  var betweens = <String>[];
  prev = a;
  for (int i = 0; i < 100; i++) {
    prev = FractionalIndex.between(before: prev, after: b);
    betweens.add(prev);
  }
  var sortedBetweens = List<String>.from(betweens)..sort();
  for (int i = 0; i < betweens.length; i++) {
    if (betweens[i] != sortedBetweens[i]) {
      print('Sort mismatch in between() at $i: ${betweens[i]} vs ${sortedBetweens[i]}');
      return;
    }
  }
  print('between() generates perfectly sorted indices.');
}
