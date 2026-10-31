# CLAUDE.md — miner-fleet-store

## THIS REPO IS WORLD-READABLE

`miner-fleet-store` is public and must stay public. umbrelOS's `umbreld` clones
it over plain git with no credentials and re-polls it on a short interval, so a
private repo cannot serve as a community app store. Everything committed here is
readable by anyone, permanently, from the moment it is pushed — the source
itself is the exposure surface, not just a published artifact.

The codespace privacy rule therefore applies here with no softening. The
following must NEVER be committed to this repo — not in a manifest, not in a
compose file, not in docs, not in a comment, not in a commit message, not in a
PR body:

- **LAN IP address** — any address on the operator's private network, in any notation
- **Hostname** — machine names, internal DNS names, mDNS names, router-assigned names
- **MAC address** — miner or host hardware addresses
- **Physical location** — street address, city, region, or anything that geolocates the deployment
- **Credential** — of any kind, in any form, including placeholder values that look real

Fleet-fingerprinting detail is out too: unit counts, serial numbers, and
per-device identifiers describe the operator's setup as precisely as an address
does. Any value that is specific to one installation is supplied by the operator
at install time through Umbrel's app configuration, never committed here.

If a value makes you hesitate, it does not go in. Stop and ask.

---

## Canonical rules apply here

The codespace canonical rules and standards are the law in this repo. They live
under `.engine-context/codespace/`:

- [`.engine-context/codespace/CLAUDE.md`](.engine-context/codespace/CLAUDE.md) — universal rules
- [`.engine-context/codespace/INVARIANTS.md`](.engine-context/codespace/INVARIANTS.md) — system-wide invariants
- [`.engine-context/codespace/DECISIONS.md`](.engine-context/codespace/DECISIONS.md) — cross-repo permanent decisions
- [`.engine-context/codespace/docs/oo-standards.md`](.engine-context/codespace/docs/oo-standards.md) — OO architecture
- [`.engine-context/codespace/docs/coding-standards.md`](.engine-context/codespace/docs/coding-standards.md) — filenames, identifier casing

Do NOT duplicate any of them here. Restating a canonical rule in this file
creates a second copy that drifts the moment the canonical one changes; read the
canonical file instead. Repo-specific extensions belong in
[`STANDARDS.md`](STANDARDS.md); permanent repo decisions belong in
[`DECISIONS.md`](DECISIONS.md) and are read before changing anything they cover.

This file adds only what is specific to this repo.

---

## What this repo is

An Umbrel Community App Store. It is the deploy mechanism for
[`miner-fleet`](https://github.com/RichardWilliams/miner-fleet), a self-hosted
fleet manager for Bitaxe and NerdQAxe++ Bitcoin ASIC miners.

This repo ships no application code. It holds declarative metadata only: a store
manifest, an app manifest, and a compose file. umbrelOS polls the repo, reads
those files, and reconciles the running container against them. Publishing a new
release of the app means bumping the version and image digest here — the Umbrel
box is never touched directly.

The store id, the app id, the app directory name, the networking mode, and the
image-pinning rule are all settled decisions with consequences that reach into
umbrelOS's own behaviour. Read [`DECISIONS.md`](DECISIONS.md) before changing any
of them.

---

## Validation

**This repo has no `package.json`, no build, and no TypeScript.** There is no
type-check or compile command to run, and no lint command beyond the shell lint
`.local-ci.yml` runs; this file deliberately does not claim one. Do not copy a
validation command block from `miner-fleet` or any sibling repo into this file —
those commands cannot run here, and a validation section that names commands the
repo does not have is a false claim about the repo.

It does have mechanical checks. `.local-ci.yml` is the canonical step set and
the one place its steps are listed; read it there rather than from a copy. CI
runs it inside the pinned image. The push gate runs nothing itself: it lets a
push through only on a pass marker for HEAD, which only the codespace producer
writes, after building and running that SAME image with the SAME steps over a
clean clone of HEAD (cs#1823).

Some of what was once checked by hand is now a step there: the app manifest and
the compose file are parsed fail-closed as YAML by the `deploy-contract` and
`release-notes-drift` steps, the `version-drift` step fails unless the compose
carries exactly one image reference pinned by both a semver tag and a sha256
digest, and the `compose-hardening` step fails when there is no `server`
service.

Checked by hand before any push, because no step checks it in full:

1. **Privacy scan.** Confirm nothing in the tracked tree matches the banned
   classes listed at the top of this file. This is the load-bearing check for a
   public repo. The `secret-leak` step refuses credential shapes in the files a
   release bump writes; no step checks the rest of the tracked tree or the LAN
   address, hostname, MAC and location classes, so this hand check stays.
2. **The store manifest parses.** `umbrel-app-store.yml` is valid YAML; no step
   reads it.
3. **Naming matches `DECISIONS.md`.** Store id, app id, app directory name and
   `app_proxy`'s `APP_HOST` all agree with the recorded naming decision.
   `APP_HOST` is the one that fails silently — the container stays healthy and
   only the proxy in front of it resolves nothing.

When this repo eventually gains a mechanical check for any of the above, it is
declared once in `.local-ci.yml` so CI and the producer behind the push gate run
the same thing — and this section is updated to point at it rather than
describing it twice.

---

## Bootstrap / disaster recovery

Every one of the 38 symlinks under `.claude/` points into `.engine-context/`,
which is deliberately excluded from version control via `.git/info/exclude`
rather than the committed `.gitignore` — this matches the canonical
managed-repo pattern, where the snapshot is a local materialisation, not a
tracked artifact. On a bare clone, or after any disaster-recovery
re-checkout, `.engine-context/` does not exist and all 38 symlinks dangle.
`.claude/settings.json` is itself gitignored and is only produced by
`sync-settings.sh` / `worktree-new.sh` reading
`.claude/canonical/hook-registrations.json` — which cannot resolve while it
too is a dangling symlink. The net effect is silent, not loud: no
PreToolUse hook fires, no `scan-write-content.sh`, no
`scan-diff-banned-tokens.sh`, no privacy scan — nothing errors, the checkout
simply looks normal while carrying zero enforcement. That is the worst
possible failure mode for a repo whose headline constraint is "world-readable,
never leak a LAN IP / hostname / MAC / credential, permanently."

**This is disaster recovery on an already-managed repo, not virgin bootstrap.**
All 38 `.claude/` symlinks — including `.claude/hooks`, `.claude/shared`,
and `.claude/canonical/hook-registrations.json`
— are tracked in git (`git ls-tree HEAD` shows mode `120000`) and reappear on
any clone or checkout automatically. They will be present but DANGLING until
`.engine-context/` is materialised. Do not try to (re-)create any of them —
`ln -s` on a path that already exists fails with `File exists`, and creating
them is unnecessary: git already restored them.

The real recovery sequence is two steps:

1. Run `realign-engine-context.sh <worktree> <codespace>`. This materialises
   the `.engine-context/` snapshot that every tracked symlink points into, and
   writes the `.engine-context/` line into `.git/info/exclude`. It detects
   this repo as managed via the already-present `.claude/hooks` symlink
   (`.claude/agents` is a plain directory of individually-symlinked files, not
   itself a detection marker) — a dangling symlink still satisfies that
   detection (`-L` is true regardless of whether the target resolves), so this
   step runs correctly with no prior symlink-creation step.
2. Run `sync-settings.sh --repo <worktree>` to generate `.claude/settings.json`
   from the now-resolvable `.claude/canonical/hook-registrations.json` and the
   repo's tracked `.claude/settings.local-additions.json`. Then VERIFY the
   result actually registers hooks, not merely that the file exists — a
   generated file with an empty `hooks` array satisfies `ls` while enforcing
   nothing:

   ```
   jq -e '(.hooks | length) > 0' .claude/settings.json
   ```

   Exit 0 with a truthy count means hooks are registered. Until this passes,
   no PreToolUse hook fires — no `scan-write-content.sh`, no
   `scan-diff-banned-tokens.sh`, no privacy scan.

**Applies to bootstrapping a brand-new managed repo, NOT to recovery on this
one — keep separate:** `realign-engine-context.sh` and `bootstrap-codespace.sh`
are silent no-ops on a repo that has no `.claude/agents` or `.claude/hooks`
symlink yet at all (the virgin case this repo itself went through once,
before its first commit). `bootstrap-codespace.sh` prints a success message
unconditionally, even when the underlying realign step no-oped, so its output
must never be trusted as evidence the snapshot materialised — verify directly
by checking that `.engine-context/codespace/` actually exists. This trap does
NOT apply to recovery on this repo, because this repo's symlinks are tracked
and therefore already present (dangling, not absent); it is listed here only
so the two procedures are not confused.

**Do not run `migrate-shared-symlinks.sh` for this repo.** It is
workspace-wide and has no `--repo` flag; invoking it here would operate across
every managed repo, not just this one. The per-file agent symlinks under
`.claude/agents/` are tracked too, so `migrate-agents-to-symlinks.sh` is
likewise unnecessary for recovery — git checkout already restored them.

Until `.engine-context/` is materialised AND `.claude/settings.json` is
regenerated with a non-empty `hooks` entry, the entire `.claude/` hook estate
is inert and this repo's privacy protections described above are **not**
enforced. That matters more here than in any sibling repo: this repo is
permanently public, so a leak that a hook would have caught elsewhere is
unrecoverable the moment it is pushed.
