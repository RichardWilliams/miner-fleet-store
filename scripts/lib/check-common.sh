#!/usr/bin/env bash
#
# Shared fail() helper for this repo's push-time compose gates
# (check-version-drift.sh, check-bind-mount-dirs.sh, check-compose-hardening.sh).
# All three previously carried a byte-identical four-line fail() differing only
# in the literal diagnostic prefix; this is that one seam extracted, the same
# way tests/lib/bash-test-harness.sh already extracts the suites' shared runner.
#
# SOURCE this file, never execute it — mode 644, matching bash-test-harness.sh.
#
# The diagnostic prefix is derived from the CALLING script's own filename via
# ${BASH_SOURCE[1]} — index 0 is this file's own source frame, index 1 is the
# script that sourced it — so no caller needs a config line and the prefix can
# never drift out of step with the file whose name it prints. Every caller's
# own `check-<name>: FAIL: ` prefix is preserved unchanged: it is derived, not
# hardcoded, from the filename each script already has.
fail() {
  local caller
  caller="$(basename "${BASH_SOURCE[1]}" .sh)"
  printf '%s: FAIL: %s\n' "$caller" "$1" >&2
  exit 1
}
