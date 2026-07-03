void main() {
  var s = '=heerys iio nc hcaonngterdol?';
  var evens = '';
  var odds = '';
  for (int i = 0; i < s.length; i++) {
    if (i % 2 == 0) evens += s[i];
    else odds += s[i];
  }
  print('Evens: $evens');
  print('Odds: $odds');
}
