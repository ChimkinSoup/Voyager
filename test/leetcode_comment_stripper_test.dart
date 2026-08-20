import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/leetcode/leetcode_comment_stripper.dart';

void main() {
  group('stripLeetCodeLineComments', () {
    test('drops comment-only lines and trims trailing comments', () {
      const code = '''
class Solution {
  // Two pointers.
  int solve(int n) {
    int x = 5; // seed
    return x;
  }
}''';
      expect(stripLeetCodeLineComments(code, 'java'), '''
class Solution {
  int solve(int n) {
    int x = 5;
    return x;
  }
}''');
    });

    test('keeps blank lines that were already blank', () {
      const code = 'int a = 1;\n\n// gone\nint b = 2;';
      expect(stripLeetCodeLineComments(code, 'java'), 'int a = 1;\n\nint b = 2;');
    });

    test('uses # for Python and leaves // alone', () {
      const code = '# lead\nx = 1  # trail\ny = "a // b"\n# end';
      expect(stripLeetCodeLineComments(code, 'python'), 'x = 1\ny = "a // b"');
    });

    test('ignores markers inside string literals', () {
      const code = 'String u = "http://x"; // real\nchar c = \'#\';';
      expect(
        stripLeetCodeLineComments(code, 'java'),
        'String u = "http://x";\nchar c = \'#\';',
      );
    });

    test('ignores a marker inside a Python docstring and keeps the docstring',
        () {
      const code = 'def f():\n    """Not # a comment."""\n    return 1  # yes';
      expect(
        stripLeetCodeLineComments(code, 'python'),
        'def f():\n    """Not # a comment."""\n    return 1',
      );
    });

    test('leaves block comments untouched, including // inside one', () {
      const code = '/* keep\n   // inside\n*/\nint a = 1; // go';
      expect(
        stripLeetCodeLineComments(code, 'cpp'),
        '/* keep\n   // inside\n*/\nint a = 1;',
      );
    });

    test('reads Rust lifetimes as code, not as an open string', () {
      const code = "fn f<'a>(s: &'a str) -> &'a str { s } // trailing";
      expect(
        stripLeetCodeLineComments(code, 'rust'),
        "fn f<'a>(s: &'a str) -> &'a str { s }",
      );
    });

    test('ignores markers inside multi-line template and raw strings', () {
      const js = 'const s = `a\n// not a comment\nb`; // real';
      expect(
        stripLeetCodeLineComments(js, 'javascript'),
        'const s = `a\n// not a comment\nb`;',
      );
      const go = 'var s = `x\n// kept\n`\nfmt.Println(s) // dropped';
      expect(
        stripLeetCodeLineComments(go, 'go'),
        'var s = `x\n// kept\n`\nfmt.Println(s)',
      );
    });

    test('an unterminated quote does not hide the comments below it', () {
      const code = 'String bad = "oops;\nint a = 1; // dropped';
      expect(
        stripLeetCodeLineComments(code, 'java'),
        'String bad = "oops;\nint a = 1;',
      );
    });

    test('returns the same string when there is nothing to strip', () {
      const code = 'int a = 1;\nint b = 2;';
      expect(identical(stripLeetCodeLineComments(code, 'java'), code), isTrue);
      expect(stripLeetCodeLineComments('', 'java'), '');
    });
  });
}
