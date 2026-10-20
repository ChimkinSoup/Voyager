#!/bin/bash
# MD-18: run md18-ops.dart.txt tags on one profile (qa|qb) or on both at once (both),
# unlocking the vault there first (it idle-locks after 5 minutes) with $PW (default md18vault1).
#   bash qa/steps/md18-op.sh qa|qb|both <tag> [<tag>...]
P="$1"; shift
ONLY=""; [ "$P" != both ] && ONLY="--only $P"
python qa/steps/md4pair.py features/notifications/secure_vault_dialogs.dart qa/steps/md18-unlock.dart.txt --tag "${PW:-md18vault1}" $ONLY | grep -v ": OK" | cut -c1-200
for t in "$@"; do
  python qa/steps/md4pair.py features/photo_series/photo_series_detail.dart qa/steps/md18-ops.dart.txt --tag "$t" $ONLY | grep -v '^$'
done
