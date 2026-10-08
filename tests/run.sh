#!/usr/bin/env bash
# Run every tests/test_*.sh; exit non-zero if any fails.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
