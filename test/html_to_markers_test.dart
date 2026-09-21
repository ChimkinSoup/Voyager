import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/text/html_to_markers.dart';

/// The clipboard half of EMPHASIS_FORMATTING.md §7: rich HTML in, Voyager's
/// plain-text markers out. Round-tripped through `ProseMarkup` in
/// `prose_markup_test.dart` — what matters here is that the string this
/// produces is one that parser will actually read back as formatting.
void main() {
  group('the four styles', () {
    test('bold tags', () {
      expect(htmlToProseMarkers('a <b>big</b> deal'), 'a **big** deal');
      expect(
        htmlToProseMarkers('a <strong>big</strong> deal'),
        'a **big** deal',
      );
    });

    test('italic tags', () {
      expect(htmlToProseMarkers('an <i>idea</i>'), 'an *idea*');
      expect(htmlToProseMarkers('an <em>idea</em>'), 'an *idea*');
    });

    test('underline and highlight', () {
      expect(htmlToProseMarkers('<u>key</u>'), '__key__');
      expect(htmlToProseMarkers('<mark>this</mark>'), '==this==');
    });

    test('an unsupported style comes through as plain text', () {
      // §7: no marker is invented for something the syntax cannot express.
      expect(
        htmlToProseMarkers('<s>gone</s> and <a href="x">away</a>'),
        'gone and away',
      );
      expect(
        htmlToProseMarkers('<span style="color:#ff0000">red</span>'),
        'red',
      );
    });
  });

  group('nesting', () {
    test('nested tags nest their markers', () {
      expect(
        htmlToProseMarkers('<b>bold <i>and italic</i></b>'),
        '**bold *and italic***',
      );
    });

    test('crossed tags still come out properly nested', () {
      // Browsers really do emit this, and `ProseMarkup` would drop the tail of
      // a pair that crossed another one.
      expect(htmlToProseMarkers('<b><i>x</b></i>'), '***x***');
    });

    test('an unclosed tag is still balanced', () {
      expect(htmlToProseMarkers('<b>open'), '**open**');
    });

    test('an element with no text writes no markers at all', () {
      expect(htmlToProseMarkers('a<b></b>b'), 'ab');
      expect(htmlToProseMarkers('a<b>   </b>b'), 'a b');
    });
  });

  group('whitespace', () {
    test('a marker never lands against a space', () {
      // `** big**` would be literal under the flanking rule (§2.3).
      expect(htmlToProseMarkers('a <b> big </b>deal'), 'a **big** deal');
    });

    test('runs of whitespace collapse, as HTML does', () {
      expect(htmlToProseMarkers('a\n   b\tc'), 'a b c');
    });

    test('leading whitespace is dropped', () {
      expect(htmlToProseMarkers('   a'), 'a');
    });

    test('block tags break the line', () {
      expect(htmlToProseMarkers('<p>one</p><p>two</p>'), 'one\ntwo');
      expect(htmlToProseMarkers('one<br>two'), 'one\ntwo');
      expect(htmlToProseMarkers('<li>a</li><li>b</li>'), 'a\nb');
    });

    test('formatting survives a block break', () {
      expect(htmlToProseMarkers('<p><b>one</b></p><p>two</p>'), '**one**\ntwo');
    });
  });

  group('real clipboards', () {
    test('a Google Docs run is styled with a span, not a b', () {
      // §11 names Google Docs specifically, and it ships no <b> at all.
      expect(
        htmlToProseMarkers(
          '<span style="font-weight:700">bold</span> and '
          '<span style="font-style:italic">slanted</span>',
        ),
        '**bold** and *slanted*',
      );
    });

    test('a style and a tag saying the same thing write one marker', () {
      expect(htmlToProseMarkers('<b style="font-weight:bold">x</b>'), '**x**');
    });

    test('a Word stylesheet is not prose', () {
      expect(
        htmlToProseMarkers(
          '<html><head><style>p.MsoNormal {margin:0}</style></head>'
          '<body><!--[if gte mso 9]><xml></xml><![endif]-->'
          '<p class=MsoNormal><b>Hi</b></p></body></html>',
        ),
        '**Hi**',
      );
    });

    test('entities are decoded', () {
      expect(
        htmlToProseMarkers('a &amp; b &nbsp;&mdash;&nbsp; c &#39;d&#39;'),
        "a & b — c 'd'",
      );
    });

    test('an empty fragment is empty', () {
      expect(htmlToProseMarkers(''), '');
      expect(htmlToProseMarkers('<p></p>'), '');
    });
  });
}
