# Phase 28B: does Storage refuse an octet-stream upload whose first bytes look
# like a known file type? Uploads random bytes with a given hex prefix as the
# QA user to users/<uid>/vault_media/p28b-sniff-*, prints status and the
# stored contentType, then deletes it.   python p28b-sniff.py <hexprefix>...
import json, os, sys, urllib.parse, urllib.request
KEY = 'AIzaSyDR_fRIvxgs2baeNqBOmJIWiZALM-rkuo8'
EMAIL = 'voyager-qa-100@example.com'
BUCKET = 'voyager-db9de.firebasestorage.app'
j = json.load(urllib.request.urlopen(urllib.request.Request(
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + KEY,
    data=json.dumps({'email': EMAIL, 'password': 'qavoyager2026', 'returnSecureToken': True}).encode(),
    headers={'Content-Type': 'application/json'})))
tok, uid = j['idToken'], j['localId']
for i, pre in enumerate(sys.argv[1:]):
    data = bytes.fromhex(pre) + os.urandom(50000)
    name = 'users/%s/vault_media/p28b-sniff-%d' % (uid, i)
    q = urllib.parse.quote(name, safe='')
    req = urllib.request.Request('https://firebasestorage.googleapis.com/v0/b/%s/o?name=%s' % (BUCKET, q), data=data, method='POST',
                                 headers={'Authorization': 'Firebase ' + tok, 'Content-Type': 'application/octet-stream'})
    try:
        resp = json.load(urllib.request.urlopen(req))
        print(pre, 200, resp.get('contentType'))
        urllib.request.urlopen(urllib.request.Request('https://firebasestorage.googleapis.com/v0/b/%s/o/%s' % (BUCKET, q), method='DELETE', headers={'Authorization': 'Firebase ' + tok}))
    except urllib.error.HTTPError as e:
        print(pre, e.code)
