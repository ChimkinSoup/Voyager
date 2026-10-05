"""Rebuilds assets/dictionary_en.txt from a SCOWL word list.

Download the list from http://app.aspell.net/create with size 60, spelling
US + GB(-ise), variants "common", special "hacker", diacritics "strip",
format "inline", then run:

    python tool/build_dictionary.py scowl.txt

The words come from SCOWL; the order comes from the current asset, which is
by descending frequency (DICTIONARY.md §4). Words the current asset doesn't
have go at the end, A-Z. Possessives are left out because `isKnownWord`
strips `'s` itself, and anything outside a-z and apostrophes is left out
because the tokenizer never produces it.
"""

import re
import sys

ASSET = 'assets/dictionary_en.txt'

lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
words = set()
for w in lines[lines.index('---') + 1:]:
    w = w.strip().lower()
    if re.fullmatch(r"[a-z]+(?:'[a-z]+)*", w) and not w.endswith("'s"):
        words.add(w)

current = [l.strip().lower() for l in open(ASSET, encoding='utf-8') if l.strip()]
rank = {w: i for i, w in reversed(list(enumerate(current)))}
ordered = sorted(words, key=lambda w: (rank.get(w, len(current)), w))
with open(ASSET, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(ordered) + '\n')
print(len(ordered), 'words')
