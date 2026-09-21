// The acceptance table in JOBS_SMART_PASTE_HLD.md §12, as tests. The parser is
// pure, so everything the Track form's sniff and smart paste decide about a
// copied string is decided here.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/jobs/job_clipboard_parser.dart';

void main() {
  test('a bare URL is a URL and nothing else', () {
    final parsed = parseJobClipboard('https://example.com/job/1');
    expect(parsed.url, 'https://example.com/job/1');
    expect(parsed.title, isNull);
  });

  test('a URL copied without its scheme gets one', () {
    final parsed = parseJobClipboard('boards.greenhouse.io/acme/jobs/1');
    expect(parsed.url, 'https://boards.greenhouse.io/acme/jobs/1');
    expect(parsed.title, isNull);
  });

  test('title and URL split, in either order', () {
    expect(parseJobClipboard('Software Engineer https://example.com/x'), (
      title: 'Software Engineer',
      url: 'https://example.com/x',
    ));
    expect(parseJobClipboard('https://example.com/x Software Engineer'), (
      title: 'Software Engineer',
      url: 'https://example.com/x',
    ));
  });

  test('a newline separates exactly like a space', () {
    expect(parseJobClipboard('Software Engineer\nhttps://example.com/x'), (
      title: 'Software Engineer',
      url: 'https://example.com/x',
    ));
  });

  test('the title keeps its parenthetical', () {
    expect(
      parseJobClipboard('Senior Engineer (Backend) https://example.com/x'),
      (title: 'Senior Engineer (Backend)', url: 'https://example.com/x'),
    );
  });

  test('a markdown link is a title and a URL', () {
    expect(parseJobClipboard('[Backend Eng](https://example.com/x)'), (
      title: 'Backend Eng',
      url: 'https://example.com/x',
    ));
  });

  test('text with no link is all title', () {
    expect(parseJobClipboard('Just a title'), (
      title: 'Just a title',
      url: null,
    ));
  });

  test('an email address is not a URL', () {
    expect(parseJobClipboard('name@acme.com'), (
      title: 'name@acme.com',
      url: null,
    ));
  });

  test('the first link wins and the rest stay in the title', () {
    expect(
      parseJobClipboard('https://example.com/x see also https://other.com/y'),
      (title: 'see also https://other.com/y', url: 'https://example.com/x'),
    );
  });

  test('the same link copied twice is not repeated in the title', () {
    expect(parseJobClipboard('https://example.com/x https://example.com/x'), (
      title: null,
      url: 'https://example.com/x',
    ));
  });

  test('a job description is cut to the parse budget', () {
    final parsed = parseJobClipboard('word ' * 4000);
    expect(parsed.title, isNotNull);
    expect(parsed.title!.length, lessThanOrEqualTo(kJobClipboardParseBudget));
  });

  test('the budget never cuts a link in half', () {
    // The link starts inside the budget and ends past it.
    final padding = 'word ' * 98;
    final parsed = parseJobClipboard(
      '$padding https://example.com/${'a' * 60}',
    );
    expect(parsed.url, isNull);
    expect(parsed.title, isNot(contains('example.com')));
  });

  test('a scheme glued to the front of the title is not the link', () {
    expect(
      parseJobClipboard(
        'https://Software Engineer en.wikipedia.org/wiki/Shark',
      ),
      (title: 'Software Engineer', url: 'https://en.wikipedia.org/wiki/Shark'),
    );
    // The same, with the real link carrying its own scheme too.
    expect(
      parseJobClipboard(
        'https://Software Engineer https://en.wikipedia.org/wiki/Shark',
      ),
      (title: 'Software Engineer', url: 'https://en.wikipedia.org/wiki/Shark'),
    );
  });

  test('a glued scheme comes off even with no link in the string', () {
    expect(parseJobClipboard('https://Software Engineer'), (
      title: 'Software Engineer',
      url: null,
    ));
  });

  test('a scheme standing on its own is dropped', () {
    expect(parseJobClipboard('https:// Software Engineer example.com/x'), (
      title: 'Software Engineer',
      url: 'https://example.com/x',
    ));
  });

  test('the omnibox `www.` comes off with the scheme', () {
    expect(
      parseJobClipboard(
        'https://www.Data Engineer Intern '
        'coinbase.com/en-ca/careers/positions/8175459',
      ),
      (
        title: 'Data Engineer Intern',
        url: 'https://coinbase.com/en-ca/careers/positions/8175459',
      ),
    );
  });

  test('a `www.` host keeps its `www.` in the stored URL', () {
    expect(
      parseJobClipboard('Data Engineer https://www.coinbase.com/careers/1').url,
      'https://www.coinbase.com/careers/1',
    );
    expect(
      parseJobClipboard('Data Engineer www.coinbase.com/careers/1').url,
      'https://www.coinbase.com/careers/1',
    );
  });

  test('a `www.` word with no scheme is a title word too', () {
    expect(parseJobClipboard('www.Data Engineer example.com/x'), (
      title: 'www.Data Engineer',
      url: 'https://example.com/x',
    ));
  });

  test('a real host behind the scheme is still a link', () {
    expect(parseJobClipboard('https://example.com').url, 'https://example.com');
    expect(
      parseJobClipboard('https://example.com:8080/x').url,
      'https://example.com:8080/x',
    );
    expect(
      parseJobClipboard('http://localhost:3000/jobs/1').url,
      'http://localhost:3000/jobs/1',
    );
  });

  test('an empty or blank clipboard parses to nothing', () {
    expect(parseJobClipboard(''), (title: null, url: null));
    expect(parseJobClipboard('   \n  '), (title: null, url: null));
  });

  test('one layer of wrapping comes off', () {
    expect(
      parseJobClipboard('<https://example.com/x>').url,
      'https://example.com/x',
    );
    expect(parseJobClipboard('"Software Engineer"').title, 'Software Engineer');
  });

  test('punctuation prose leaves stuck to a link is trimmed', () {
    expect(
      parseJobClipboard('Apply at https://example.com/x.').url,
      'https://example.com/x',
    );
  });

  test('a word that merely ends in a dot is not a host', () {
    expect(parseJobClipboard('Engineer. Remote.'), (
      title: 'Engineer. Remote.',
      url: null,
    ));
    expect(parseJobClipboard('e.g. a role').url, isNull);
  });

  test('the title collapses the whitespace a copy came with', () {
    expect(
      parseJobClipboard('Senior   Engineer\n\nhttps://example.com/x').title,
      'Senior Engineer',
    );
  });

  test('normalize leaves a scheme it already has alone', () {
    expect(normalizeJobUrl('http://example.com'), 'http://example.com');
    expect(normalizeJobUrl('example.com/x'), 'https://example.com/x');
    expect(normalizeJobUrl('  '), isNull);
  });
}
