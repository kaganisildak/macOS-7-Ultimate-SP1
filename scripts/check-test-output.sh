#!/bin/sh
# Verifies captured `make test` output: every listed test product must have run to a passing
# "Test run with N tests ... passed" line, with N > 0 and no failure lines. A runner that dies
# silently (exit 0, no result line) fails this check.
#
# Usage: scripts/check-test-output.sh LOG PRODUCT...
# LOG holds sections that start with "=== test product: <PRODUCT>" (the Makefile prints them).
set -u

if [ $# -lt 2 ]; then
    echo "usage: $0 LOG PRODUCT..." >&2
    exit 2
fi
log=$1
shift
if [ ! -r "$log" ]; then
    echo "check-test-output: cannot read $log" >&2
    exit 2
fi

esc=$(printf '\033')
status=0
for product in "$@"; do
    # The product's section, with colour codes removed.
    section=$(sed "s/${esc}\[[0-9;]*m//g" "$log" | awk -v p="$product" '
        /^=== test product: / { inside = ($0 == "=== test product: " p); next }
        inside { print }')
    passed=$(printf '%s\n' "$section" | grep -E 'Test run with [0-9]+ tests? .*passed' || true)
    failed=$(printf '%s\n' "$section" | grep -E '^✘|Test run with .* failed' || true)
    count=$(printf '%s\n' "$passed" | sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p')
    if [ -n "$failed" ]; then
        echo "check-test-output: $product FAILED:" >&2
        printf '%s\n' "$failed" | sed 's/^/  /' >&2
        status=1
    elif [ -z "$passed" ] || [ "$(printf '%s\n' "$passed" | wc -l | tr -d ' ')" != 1 ]; then
        echo "check-test-output: $product has no passing \"Test run with N tests\" line (runner exited early or never ran)" >&2
        status=1
    elif [ "$count" -eq 0 ]; then
        echo "check-test-output: $product ran 0 tests" >&2
        status=1
    else
        echo "check-test-output: $product ok ($count tests)"
    fi
done
exit $status
