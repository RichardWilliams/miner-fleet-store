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

**This repo has no `package.json`, no build, no test runner, and no TypeScript.**
There is no lint, type-check, compile, or unit-test command to run, and this file
deliberately does not claim one. Do not copy a validation command block from
`miner-fleet` or any sibling repo into this file — those commands cannot run
here, and a validation section that names commands the repo does not have is a
false claim about the repo.

What replaces it, before any push:

1. **Privacy scan.** Confirm nothing in the tracked tree matches the banned
   classes listed at the top of this file. This is the load-bearing check for a
   public repo.
2. **YAML parses.** Every manifest and compose file is valid YAML.
3. **Naming matches `DECISIONS.md`.** Store id, app id, and app directory name
   agree with the recorded naming decision.
4. **Image reference is fully pinned.** Both a semver tag and a sha256 digest are
   present, per the recorded pinning decision.

When this repo eventually gains a mechanical check for any of the above, it is
declared once in `.local-ci.yml` so the local gate and CI run the same thing —
and this section is updated to point at it rather than describing it twice.
