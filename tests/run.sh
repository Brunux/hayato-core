#!/bin/bash
# Run every core test file. No external test runner is needed, so the same
# command works on the build host and on a minimal CI image.
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
for file in tests/test-*.sh; do
	[ -e "$file" ] || continue
	printf '\n== %s\n' "$file"
	if ! bash "$file"; then
		fail=1
	fi
done

if [ "$fail" -ne 0 ]; then
	printf '\ncore tests failed\n' >&2
	exit 1
fi
printf '\ncore tests passed\n'
