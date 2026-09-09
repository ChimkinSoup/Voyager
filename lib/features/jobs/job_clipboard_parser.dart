/// Splits one clipboard string into the title and the URL of a job posting
/// (JOBS_SMART_PASTE_HLD.md §6).
///
/// Pure, and deliberately so: the same function serves the clipboard sniff the
/// Track form runs on open and the smart paste its Title and URL fields do, so
/// the two can never disagree about what a copied string meant.
library;

/// The most of a clipboard string this parser will look at.
///
/// A copied job description runs to thousands of characters and none of it is
/// a role title, so past this point the text is dropped rather than folded
/// into one. The first of §6.1's two budget policies, kept because it is the
/// one that needs no line analysis: a posting's title and link together never
/// come close to 500 characters.
const int kJobClipboardParseBudget = 500;

/// What one clipboard string turned out to hold. Either half may be null —
/// a bare URL has no title in it, and most text has no link.
typedef JobClipboardParse = ({String? title, String? url});

const JobClipboardParse _nothing = (title: null, url: null);

/// `[Role title](https://…)` — a link copied out of a markdown document.
final _markdownLink = RegExp(r'^\[([^\]]*)\]\(([^)\s]+)\)$');

/// The prefix an address bar leaves glued to the front of text pasted through
/// it: its scheme, and the `www.` an omnibox completes after it.
///
/// This is the whole reason a token starting `https://` is not automatically a
/// link. Paste a title and a link into an address bar and copy the result back
/// and the prefix comes with it — `https://Software Engineer
/// en.wikipedia.org/wiki/Shark`, `https://www.Data Engineer Intern
/// coinbase.com/en-ca/careers/positions/8175459`. The first token is a title
/// word wearing a URL's clothes.
final _gluedPrefix = RegExp(r'^https?://(?:www\.)?', caseSensitive: false);

/// `www.` on its own, which a token can carry without a scheme.
final _leadingWww = RegExp(r'^www\.', caseSensitive: false);

/// What has to remain once [_gluedPrefix] comes off for the token to have been
/// a link after all: a dotted host with a two-letter-or-longer last label, or
/// `localhost`, then a port, path, query, fragment, or nothing.
///
/// The dot is what does the work. `Data` and `Software` have none left once
/// the prefix is gone, while `coinbase.com/en-ca/…` and `example.com:8080/x`
/// still read as hosts. Looser than [_bareHost] about `@`, which a scheme
/// makes userinfo rather than an email address.
final _hostBehindPrefix = RegExp(
  r'^(?:[^/?#\s]*\.[a-z]{2,}|localhost)(?:[:/?#]|$)',
  caseSensitive: false,
);

/// Any scheme at all, which is the test [normalizeJobUrl] uses before adding
/// one: a markdown link may legitimately point at `mailto:` or `obsidian://`.
final _anyScheme = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false);

/// `host.tld`, optionally with a path, query or fragment after it.
///
/// The last label has to be two or more letters, which is what keeps `e.g`,
/// `v2.0` and a sentence's `word.` out of the URL field. It does not keep
/// `Node.js` out — a title token that reads exactly like a host is
/// indistinguishable from one, and the "From clipboard" chip is there to make
/// that cheap to undo.
final _bareHost = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?'
  r'(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*'
  r'\.[a-z]{2,}(?:[/?#].*)?$',
  caseSensitive: false,
);

/// Punctuation prose leaves stuck to the end of a link.
const _trailingPunctuation = '.,;)]';

/// One layer of quoting or bracketing around the whole string.
const _wrappers = {'"': '"', "'": "'", '<': '>'};

/// Reads [raw] as a job posting: a title, an application URL, or both.
///
/// Spaces and newlines are the same separator, order does not matter, and the
/// first URL-shaped token wins — everything else is title.
JobClipboardParse parseJobClipboard(String raw) {
  final text = _unwrap(_withinBudget(raw));
  if (text.isEmpty) return _nothing;

  final link = _markdownLink.firstMatch(text);
  if (link != null) {
    final title = link.group(1)!.trim();
    return (
      title: title.isEmpty ? null : title,
      url: normalizeJobUrl(link.group(2)!),
    );
  }

  String? urlToken;
  final rest = <String>[];
  for (final token in text.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (_isUrlToken(token)) {
      if (urlToken == null) {
        urlToken = token;
        continue;
      }
      // A second, different link stays in the title: it is text as far as this
      // form is concerned, and it keeps its scheme because it is still a link.
      // The *same* link copied twice is not worth keeping.
      if (token != urlToken) rest.add(token);
      continue;
    }
    // Not a link, so a scheme on its front belongs to the address bar the text
    // came out of rather than to the title. A token that was nothing but that
    // prefix leaves nothing behind and is dropped.
    final word = token.replaceFirst(_gluedPrefix, '');
    if (word.isNotEmpty) rest.add(word);
  }

  // Joined on single spaces, which is also how the newlines a multi-line copy
  // arrives with become something a one-line field can hold.
  final title = rest.join(' ');
  return (
    title: title.isEmpty ? null : title,
    url: urlToken == null ? null : normalizeJobUrl(urlToken),
  );
}

/// The URL as it should be stored: trailing prose punctuation off, and a
/// scheme on the front of a token copied without one (§6.5).
String? normalizeJobUrl(String token) {
  final trimmed = _trimTrailingPunctuation(token.trim());
  if (trimmed.isEmpty) return null;
  return _anyScheme.hasMatch(trimmed) ? trimmed : 'https://$trimmed';
}

/// Whether [token] reads as a link rather than as a word of the title.
///
/// An address is never one: `name@acme.com` is host-shaped and is not a job
/// posting, so an `@` outside a scheme rules the token out.
bool _isUrlToken(String token) {
  final trimmed = _trimTrailingPunctuation(token);
  final glue = _gluedPrefix.firstMatch(trimmed);
  if (glue != null) {
    return _hostBehindPrefix.hasMatch(trimmed.substring(glue.end));
  }
  if (trimmed.contains('@')) return false;
  // The same `www.` rule, for a token that arrived without a scheme, so that
  // `www.Data` and `https://www.Data` do not disagree about what they are.
  return _bareHost.hasMatch(trimmed.replaceFirst(_leadingWww, ''));
}

String _withinBudget(String raw) {
  final text = raw.trim();
  if (text.length <= kJobClipboardParseBudget) return text;
  final clipped = text.substring(0, kJobClipboardParseBudget);
  // Cut back to the last whitespace so the budget can never end halfway
  // through a link and hand the field a URL that goes nowhere.
  final lastBreak = clipped.lastIndexOf(RegExp(r'\s'));
  return (lastBreak <= 0 ? clipped : clipped.substring(0, lastBreak)).trim();
}

String _unwrap(String text) {
  if (text.length < 2) return text;
  final closing = _wrappers[text[0]];
  if (closing == null || !text.endsWith(closing)) return text;
  return text.substring(1, text.length - 1).trim();
}

String _trimTrailingPunctuation(String token) {
  var end = token.length;
  while (end > 0 && _trailingPunctuation.contains(token[end - 1])) {
    end--;
  }
  return token.substring(0, end);
}
