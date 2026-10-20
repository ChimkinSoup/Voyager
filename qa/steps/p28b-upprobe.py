# Phase 28B: upload a local vault file to Storage as the QA user (Firebase
# REST, ID token from email/password), like the app's putData.
#   python p28b-upprobe.py <localName> <remoteName> [--delete]
import json, os, sys, urllib.parse, urllib.request
KEY = 'AIzaSyDR_fRIvxgs2baeNqBOmJIWiZALM-rkuo8'
EMAIL = 'voyager-qa-100@example.com'
assert EMAIL.startswith('voyager-qa-')
BUCKET = 'voyager-db9de.firebasestorage.app'
D = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\vault_media')
r = urllib.request.urlopen(urllib.request.Request(
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + KEY,
    data=json.dumps({'email': EMAIL, 'password': 'qavoyager2026', 'returnSecureToken': True}).encode(),
    headers={'Content-Type': 'application/json'}))
j = json.load(r)
tok, uid = j['idToken'], j['localId']
name = 'users/%s/vault_media/%s' % (uid, sys.argv[2])
url = 'https://firebasestorage.googleapis.com/v0/b/%s/o?name=%s' % (BUCKET, urllib.parse.quote(name, safe=''))
data = open(os.path.join(D, sys.argv[1]), 'rb').read()
req = urllib.request.Request(url, data=data, method='POST', headers={'Authorization': 'Firebase ' + tok, 'Content-Type': 'application/octet-stream'})
try:
    print('upload', sys.argv[2], len(data), urllib.request.urlopen(req).status)
except urllib.error.HTTPError as e:
    print('upload', sys.argv[2], len(data), e.code, e.read()[:300])
if '--delete' in sys.argv:
    dreq = urllib.request.Request('https://firebasestorage.googleapis.com/v0/b/%s/o/%s' % (BUCKET, urllib.parse.quote(name, safe='')), method='DELETE', headers={'Authorization': 'Firebase ' + tok})
    try:
        print('delete', urllib.request.urlopen(dreq).status)
    except urllib.error.HTTPError as e:
        print('delete', e.code)
