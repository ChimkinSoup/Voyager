void main() {
  var s1 = 'there is no version control?';
  var s2 = 'heerys iio nc hcaonngterdol?';
  
  var list1 = s1.split('')..sort();
  var list2 = s2.split('')..sort();
  
  print('s1: ${list1.join()}');
  print('s2: ${list2.join()}');
  print('Equal? ${list1.join() == list2.join()}');
}
