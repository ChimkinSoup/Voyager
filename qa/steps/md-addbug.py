"""Append bug entries (a UTF-8 text file, LF or CRLF) to qa/BUGS.md before its
"Last ID" marker, and move the marker to the last ### BUG-NNN in the text.

    python qa/steps/md-addbug.py <entries.txt>
"""
import re, sys

path = 'qa/BUGS.md'
s = open(path, encoding='utf-8', newline='').read()
new = open(sys.argv[1], encoding='utf-8').read().replace('\r\n', '\n').strip('\n')
last = re.findall(r'^### (BUG-\d+)', new, re.M)[-1]
marker = re.search(r'<!-- Last ID: BUG-\d+\. -->', s)
block = new.replace('\n', '\r\n') + '\r\n\r\n'
s = s[:marker.start()] + block + f'<!-- Last ID: {last}. -->' + s[marker.end():]
open(path, 'w', encoding='utf-8', newline='').write(s)
print('added through', last)
