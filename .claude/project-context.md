# Project Context

This is `miner-fleet-store`: the Umbrel Community App Store that distributes
`miner-fleet` to the operator's own Umbrel Home box. It is a distribution
channel, not an application. Review it as release infrastructure — the questions
that matter are "does umbrelOS resolve this correctly?" and "is this safe to
publish to the world?", not "is this code well-factored", because there is
almost no code here to factor.

## What is actually in this repo

- **Declarative metadata plus one guard.** A store manifest, an app manifest, a
  compose file and the app icon. No application source, no `package.json`, no
  build step, no TypeScript. A reviewer looking for a type-check gate should
  expect to find none — that absence is the design, not a gap. There IS a shell
  check (`scripts/check-version-drift.sh`) with its own test suite, wired into
  `.local-ci.yml`; it guards the one thing this repo can get silently wrong,
  which is the app manifest's `version` disagreeing with the compose image tag.
- **A machine consumer, not a human one.** umbrelOS's `umbreld` clones this repo
  over plain git and re-polls it on a short interval, parses the manifests, and
  reconciles the running container against them. Errors surface as an app that
  quietly fails to appear or fails to install, rarely as a readable message. A
  malformed field here is a silent production failure, which is why manifest
  correctness carries more weight than it would in a repo with a compiler.
- **The store is live.** The store manifest, the `pipfox-miner-fleet/` app
  directory, its app manifest and its compose file all exist, pinning a real
  `miner-fleet` semver release by tag AND digest. The five permanent constraints
  that govern them — naming (including the compose service name), bridge
  networking, tag+digest pinning, which digest form to pin, and icon hosting —
  are recorded in `DECISIONS.md`. Read it before changing any of them; each was
  chosen against an alternative that fails silently rather than loudly.

## The world-readable constraint dominates everything

This repo is public and cannot become private: `umbreld` clones it with no
credentials, so a private store is not installable. Every commit is a permanent
publication.

Weight privacy findings accordingly. A LAN IP address, a hostname, a MAC address,
anything that geolocates the deployment, any credential, or any value that
fingerprints the fleet (unit counts, serial numbers, per-device identifiers) is a
blocking finding here even when the same value would be a minor note in a private
repo. Installation-specific values belong in Umbrel's app configuration, supplied
by the operator at install time.

## Review posture

- **Give strong opinions.** Challenge naming, challenge the compose shape,
  challenge whether a decision recorded in `DECISIONS.md` still holds given what
  the diff actually does. Surface what is worth considering; the operator decides
  what to act on.
- **Check the diff against `DECISIONS.md` literally.** Store/app naming,
  networking mode, and image pinning are settled decisions with recorded
  rationale. A diff that contradicts one is a finding regardless of whether the
  contradiction looks reasonable in isolation — the decision, or the diff, has to
  change, and the decision entry names the conditions for revisiting it.
- **Security scrutiny scoped to the real surface.** The exposure here is what
  gets published (privacy) and what the compose file grants the container
  (capabilities, mounts, network mode, exposed ports). Application-level
  vulnerability classes have no code here to live in.
- **Single-operator home lab.** Multi-tenancy, rate limiting, and SLA findings
  are unlikely to apply. Raise a genuine concern anyway if you see one; use
  judgement rather than a blanket suppression.
