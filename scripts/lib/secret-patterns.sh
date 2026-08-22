#!/usr/bin/env bash
#
# The one declaration of the credential shapes this repo refuses to publish,
# and the one function that looks for them.
#
# WHY THIS EXISTS. This repo is PUBLIC and its history is permanent. The repo it
# copies operator-facing text FROM is private. `scripts/release.sh` fetches two
# human-authored artefacts from that private repo — the GitHub Release body and
# `deploy/contract.json`, whose `documentation.*` fields are free prose — and
# commits both here. Before this file the only content checks on either artefact
# were the three markdown refusals and the folded-scalar emitter check, and the
# contract was copied in with no content check at all: a credential pasted into
# a Release body upstream would have become permanently public here with nothing
# in its way.
#
# WHY A CATEGORY NAME AND NEVER THE MATCH. A refusal that echoed the matched
# text would disclose the credential a second time — into the operator's
# terminal, their shell history, and the CI log of every run that reproduced it.
# Callers therefore receive a CATEGORY LABEL and nothing else: `grep -q` prints
# no match, and the nameref carries back a label drawn from the table below.
#
# BOTH CONSUMERS ARE TESTED FOR IT, which is what makes that a checkable
# property rather than a promise. tests/test-check-secret-leak.sh's "the
# contract refusal never echoes the matched text" covers the push-time gate, and
# tests/test-release.sh's no-echo helper covers the driver, at both the Release
# body and the deployment contract. Each plants a known credential-shaped value
# and greps the whole failure output for it.
#
# WHAT IS DELIBERATELY NOT HERE: private-range and loopback IP literals. They
# were considered and REFUSED. This application's whole purpose is sweeping the
# operator's own LAN, so its release notes legitimately instruct the operator to
# set values like a `192.168.x.0/24` subnet, and DEPLOY.md § 6 does the same. A
# check refusing private-range literals would have blocked the shipped 0.2.0
# release and would block the next release that explains subnet configuration.
# Those addresses are necessary operator-facing prose in this repo, not a leak.
# DECISIONS.md entry 15 records the refusal so it is not re-proposed.
#
# SOURCE this file, never execute it — mode 644, the same convention as
# scripts/lib/check-common.sh and scripts/lib/repo-context.sh.

# --- the categories ----------------------------------------------------------
#
# Two index-aligned arrays rather than one associative array: bash gives an
# associative array no iteration order, so a file matching two categories would
# be reported with whichever label the hash happened to yield first, and the
# message would not be reproducible. Row N of each array is one category.
#
# Every pattern is a POSIX ERE — no \d, \s or \b (INVARIANTS.md § Tool
# invocation correctness) — and every one is anchored on a VENDOR-ASSIGNED
# PREFIX followed by a run of credential-alphabet characters. That shape is what
# keeps the check from ever blocking a correct release: the prose these
# artefacts carry is operator guidance about a home network, and no sentence in
# it opens with `AKIA`, `ghp_`, `sk-` or a PEM armour line and then continues
# with twenty-odd unbroken token characters.

SECRET_CATEGORY_LABELS=(
  "an AWS access-key ID"
  "a GitHub token"
  "a PEM private-key header"
  "an sk- style API key"
)

# Row 1: the ten documented AWS access-key-ID prefixes plus the sixteen
#        uppercase-alphanumeric characters that complete the twenty-character id.
# Row 2: the five classic GitHub token prefixes and the fine-grained
#        `github_pat_` prefix. The published classic length is thirty-six
#        characters, but the minimum here is twenty: a truncated or
#        future-length token is still a credential, and the prefix is what
#        discriminates it from prose.
# Row 3: the PEM armour line, whatever key type it names (RSA, EC, OPENSSH,
#        ENCRYPTED, or none at all).
# Row 4: the `sk-` API-key spelling used by several providers, including the
#        `sk-proj-` variant, which is why the run admits `-` and `_`.
SECRET_CATEGORY_PATTERNS=(
  '(AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AIPA|ANPA|ANVA|AROA)[0-9A-Z]{16}'
  '(ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}'
  '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
  'sk-[0-9A-Za-z_-]{20,}'
)

# A row present in one array and missing from the other would silently drop a
# category or mislabel a match, so the pairing is asserted the moment this file
# is sourced. `exit` rather than `return` is deliberate and is the fail-closed
# choice: a consumer that cannot trust the table must not run at all, and at
# source time this statement is not inside a subshell, so the exit reaches the
# consumer's own process.
if (( ${#SECRET_CATEGORY_LABELS[@]} != ${#SECRET_CATEGORY_PATTERNS[@]} )); then
  printf 'secret-patterns: FAIL: %d category labels but %d patterns; the two arrays in scripts/lib/secret-patterns.sh are index-aligned and must be the same length\n' \
    "${#SECRET_CATEGORY_LABELS[@]}" "${#SECRET_CATEGORY_PATTERNS[@]}" >&2
  exit 1
fi

# --- the scan ----------------------------------------------------------------

# secret_scan_file <category-variable-name> <path>
#
# Return 0 when <path> carries none of the categories above, leaving the named
# variable empty. Return 1 when it carries one, with the named variable set to
# that category's label — never to the matched text.
#
# The result comes back through a nameref rather than on stdout, which is the
# same shape `check-deploy-contract.sh`'s `read_lines` uses, and here it is
# load-bearing rather than stylistic: a caller capturing stdout would run this
# function in a subshell, and the hard failures below would then kill only that
# subshell and read to the caller as a clean file. Through a nameref the
# function runs in the caller's own shell, so a scan that cannot read its input
# stops the caller instead of passing.
secret_scan_file() {
  local -n found_category="$1"
  local file="$2"
  found_category=""

  local index=0 status=0
  for (( index = 0; index < ${#SECRET_CATEGORY_PATTERNS[@]}; index++ )); do
    status=0
    # LC_ALL=C so the character classes mean bytes rather than whatever the
    # invoking locale makes of them, and so a non-UTF-8 byte in the file cannot
    # make grep give up on the line that carries the credential.
    #
    # `-e` rather than a bare pattern argument: the PEM row begins with `-`, and
    # as a positional argument grep reads it as a run of unknown options and
    # exits 2. That would have hit the unreadable-file branch below on EVERY
    # file, which is fail-closed but useless.
    LC_ALL=C grep -qE -e "${SECRET_CATEGORY_PATTERNS[index]}" "$file" || status=$?

    if (( status == 0 )); then
      found_category="${SECRET_CATEGORY_LABELS[index]}"
      return 1
    fi
    # grep says 1 for "no match" and 2 for "could not read it". Treating the
    # second as the first is exactly how a scanner reports a file it never
    # managed to open as clean, so it is a hard failure here.
    if (( status != 1 )); then
      printf 'secret-patterns: FAIL: could not scan %s for credentials (grep exited %d). A file this check cannot read is not a file it can clear.\n' \
        "$file" "$status" >&2
      exit 1
    fi
  done

  return 0
}

# The half of the refusal that is the same wherever the credential was found.
# Each caller adds the sentence naming ITS OWN source and remedy; this states
# the part neither of them owns.
SECRET_LEAK_RATIONALE="This repo is public and its git history is permanent, so a credential committed here is disclosed the moment the branch is pushed and stays disclosed after any later deletion. The matched text is deliberately not printed: echoing it into a terminal, a shell history or a CI log would disclose it again. Treat the credential as compromised, rotate it, and remove it at its source."
