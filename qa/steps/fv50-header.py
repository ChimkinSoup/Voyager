# FV-50: does users/<uid>/secure_vault/header exist for a QA account?  python fv50-header.py <email>
import json, sys, urllib.request
KEY = 'AIzaSyDR_fRIvxgs2baeNqBOmJIWiZALM-rkuo8'
EMAIL = sys.argv[1]
assert EMAIL.startswith('voyager-qa-')
j = json.load(urllib.request.urlopen(urllib.request.Request(
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + KEY,
    data=json.dumps({'email': EMAIL, 'password': 'qavoyager2026', 'returnSecureToken': True}).encode(),
    headers={'Content-Type': 'application/json'})))
url = 'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/%s/secure_vault/header' % j['localId']
try:
    d = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + j['idToken']})))
    print('header exists, vaultId', d['fields'].get('vaultId', {}).get('stringValue'))
except urllib.error.HTTPError as e:
    print('header', e.code)
