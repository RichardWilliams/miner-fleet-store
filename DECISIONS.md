# DECISIONS

Permanent decisions for this repo. Each entry carries Statement / Why /
Revisit-if. Entries are appended as part of the originating PR that makes the
decision, atomic with the structural change that implements it (codespace
CLAUDE.md RULE #0).

Entries 1-3 transcribe decisions the operator settled while scoping the store
work, recorded in `miner-fleet-store#1`'s issue body; they were captured by the
bootstrap PR ahead of the structural change that implements them. Entries 4-5
are decisions made by `#1` itself — the PR that landed the manifests, the compose
file and the directory layout — and are appended by that PR, atomic with the
change, per codespace CLAUDE.md RULE #0. Entry 6's ownership claim was corrected,
and entry 8 appended, by the PR closing `#8` — the fix for a fresh-install
crash loop caused by that entry's original, unverified claim about who creates
and owns the bind-mount source. That same PR appended entry 9, recording the
gate it added to enforce the `server` service's hardening mechanically.

---

## 1. Store id `pipfox`, app id `pipfox-miner-fleet`, app directory name equal to the app id, compose service named `server`

**Statement.** The store id is `pipfox`. The app id is `pipfox-miner-fleet`. The
app directory at the repo root is named `pipfox-miner-fleet` — byte-for-byte the
app id, with no suffix, no variation, and no separate display slug. The
application service in `docker-compose.yml` is named `server`, and `app_proxy`'s
`APP_HOST` is `pipfox-miner-fleet_server_1`. These four names are one identifier
chain: each derives from the one before it, so changing any name requires
updating everything downstream of it in the same commit — a store-id change
reaches all four, a service rename reaches only `APP_HOST`.

**Why.** umbrelOS imposes the first two links. An app id must be
prefixed with the id of the store that ships it, so the app cannot be called
`miner-fleet` while the store is called `pipfox` — umbreld will not resolve it.
And the app is located on disk by its id, so the directory name must equal the
app id exactly; a mismatch makes the app invisible to the store scan rather than
producing a diagnosable error. Because the store id feeds the app id and the app
id feeds the directory name, a partial rename leaves the store in a state that
looks correct in the diff and silently fails to install.

The service name is the fourth link in that same chain, and fails the same way.
Umbrel injects `app_proxy` — the reverse proxy and authentication layer in front
of the app — and it locates the application container by the compose-generated
name in `APP_HOST`. Compose derives that name from the project (the app id) and
the service, so `pipfox-miner-fleet_server_1` is only correct while the service
is literally named `server`. Rename the service, or change the app id without
updating `APP_HOST`, and the container starts healthy while the proxy in front of
it resolves nothing: the operator sees a gateway error in the browser and no
indication anywhere that the configuration is wrong.

**Revisit if.** umbrelOS drops the store-id prefix requirement, the
id-equals-directory-name requirement, or `app_proxy`'s `<app-id>_server_1`
host-resolution convention; or the operator retires the `pipfox` store identity
in favour of a different one. A store-identity change sits at the head of the
chain, so it moves all four names in a single commit.

---

## 2. The app runs on bridge networking, not `network_mode: host`

**Statement.** The app's compose service uses standard Docker bridge networking.
`network_mode: host` is not used.

**Why.** The functional requirement is that the container can reach arbitrary
miners on the operator's LAN over TCP/HTTP. A bridge-networked container already
does this — outbound connections to LAN addresses are routed normally, so a
sweep over the miners' HTTP API works without host networking. `network_mode:
host` buys exactly one additional capability: receiving broadcast and mDNS
traffic, which matters only for discovery-by-announcement. The fleet is
enumerated by sweeping a known address range instead, so that capability is not
needed. The cost of taking it anyway is concrete: Umbrel's `app_proxy` — which
provides the app's authentication layer and its reverse proxy — does not work for
a host-networked service, so choosing `network_mode: host` means giving up
authentication in front of the app.

**Revisit if.** Discovery genuinely requires broadcast or mDNS (a sweep over the
known range proves insufficient in practice), AND an authentication path that
does not depend on `app_proxy` is designed first. Both conditions must hold —
the second is not optional, because dropping `app_proxy` without a replacement
removes the only thing standing in front of the app.

---

## 3. The image is pinned by semver tag AND sha256 digest together

**Statement.** The image reference in the compose file carries both a semver tag
and a sha256 digest, in the form `<image>:<semver>@sha256:<digest>`. Three forms
are banned: `latest` (or any moving tag), a bare commit SHA as the tag, and a
digest with no tag beside it.

**Why.** The two identifiers do different jobs and neither substitutes for the
other. The digest is what makes a deployment reproducible — it names exactly one
image, so what umbreld pulls is what was tested, and a re-tagged upstream cannot
silently change what runs. The tag is what makes the deployment legible — a human
reading the compose file, or an operator deciding whether to accept an update,
needs to know which release this is; a bare digest is unreadable and a bare
commit SHA carries no ordering, so neither answers "is this newer than what I am
running". `latest` fails both jobs at once: it is neither reproducible nor
informative, and it turns every unrelated upstream push into an unrequested
deployment change. Together, tag-plus-digest gives a reference that a human can
read and a machine cannot misresolve.

**Revisit if.** umbrelOS's manifest format stops accepting a combined
tag-and-digest reference, or a release process is adopted that provides an
equally reproducible and equally legible identifier — the requirement is the pair
of properties, not this particular syntax.

---

## 4. The pinned digest is the multi-arch INDEX digest, not a per-platform manifest digest

**Statement.** The `@sha256:` value in `docker-compose.yml` is the digest of the
multi-arch image INDEX — the value on the `Digest:` line of
`docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z`. It
is NOT any of the per-platform manifest digests listed underneath it in that
command's `Manifests:` section. DEPLOY.md § 3 step 1 states which line to read.

**Why.** Both values are valid 64-hex digests and both are immutable, so nothing
about the syntax distinguishes them and no check catches the wrong one: a
per-platform digest is *silently correct today and silently wrong the moment the
index changes*. umbreld resolves the index and selects the platform entry from
it, so pinning an inner manifest bypasses that selection and couples the store to
one specific platform build. Today the index contains exactly one real platform
(`linux/amd64`, entry 4) plus an attestation manifest, which is precisely what
makes the mistake invisible — the wrong pin would deploy correctly right up until
the release that adds or changes a platform, at which point it breaks with no
diff to explain it.

The distinction is a CORRECTNESS property, not a security one. Both forms are
equally immutable content-addressable pins; the security review confirmed the
supply-chain guarantee is identical either way. What differs is whether umbreld
can still resolve the right artefact after the index changes.

**Revisit if.** umbreld changes how it resolves image references (verify against
its source, not by observing that a deployment happened to work), or the image
stops being published as a multi-arch index, or miner-fleet's runtime image stops
carrying `node` with a global `fetch` — the compose healthcheck shells out to
both, an assumption that lives in the sibling repo's Dockerfile and nothing here
guards.

---

## 5. The app icon is self-hosted in this repo and referenced by its raw URL

**Statement.** The icon asset is committed at `pipfox-miner-fleet/icon.svg` and
`umbrel-app.yml`'s `icon:` field points at this repo's own
`raw.githubusercontent.com` URL on the `main` ref. It is NOT hosted on a
third-party image host such as svgur or imgur, and the URL is deliberately NOT
pinned to a commit SHA.

**Why.** Umbrel renders the tile from an https URL, and a community-store app
directory holds only the two YAML files, so the icon must be hosted somewhere.
Self-hosting keeps it versioned with the manifest that references it and puts no
third party in the dashboard's render path.

The `main` ref is a deliberate exception to entry 3's pinning discipline, on
mechanical grounds: a commit-SHA-pinned icon URL cannot be authored in the commit
that introduces the icon, and squash-merge destroys the branch SHA, so it could
only be set by a post-merge edit. The risk it would remove — a hostile icon
force-pushed over `main` — already requires write access to this repo, at which
point the `icon:` field is equally rewritable. Entry 3's digest pin is different
in kind: it defends against a compromised registry credential with no git access.
`gallery` entries follow this same rule.

**Revisit if.** Umbrel supports a directory-relative icon path, or this repo
takes external contributors — at which point `main` is no longer operator-only
and the trade-off changes shape.

---

## 6. Persistent state is a `${APP_DATA_DIR}/data:/data` bind mount, declared with the release that writes to it

**Statement.** The `server` service mounts `${APP_DATA_DIR}/data` onto the
container's `/data` — the app's default `MINER_FLEET_DATA_DIR`. The mount is
declared in the same store release that pins the first image which writes to
disk (miner-fleet `0.2.0`), never before and never after it.

**Why.** miner-fleet `0.2.0` persists its discovered inventory and telemetry
samples to a SQLite database under its data directory; without a declared volume
umbreld replaces the container on every version bump and that state is destroyed,
with the symptom (inventory empties after an update) sitting far from the cause
(no volume). `${APP_DATA_DIR}/data:/data` is the documented, shipped Umbrel
pattern — `${APP_DATA_DIR}` is the host-side app-data directory umbreld exports
into the compose environment. That contract — the `export APP_DATA_DIR`, its
`${UMBREL_ROOT}/app-data/${app}` value, and the `MINER_FLEET_DATA_DIR` = `/data`
default it feeds — is established and cited in the SIBLING repo (miner-fleet
`DECISIONS.md` entry 12 and `src/config/runtimeConfig.ts`), which owns it. This
store relies on that citation rather than re-deriving a second set of upstream
`file:line`s: those line numbers drift with every upstream commit (the
`legacy-compat/app-script` export/build lines have already moved across umbreld
releases), so pinning them here only creates a third copy to rot. The directory
**survives app updates and is removed only on uninstall**: umbreld's update copies
the app files (including this `docker-compose.yml`, so a new `volumes:` / `env_file:`
lands) over an explicit whitelist that never includes the `data/` subdirectory, and
uninstall removes the whole data directory via `app.ts`'s
`fse.remove(this.dataDirectory)`. The shipped precedent is vaultwarden's
`${APP_DATA_DIR}/data:/data`. An earlier version of this entry cited
vaultwarden's `user: "1000:1000"` line as the reason that mount is writable —
that was wrong and shipped a fresh-install crash loop (`#8`): `user:` governs
which uid the CONTAINER runs as and has no bearing on how Docker creates a
MISSING bind-mount source on the HOST side. What actually makes vaultwarden's
mount (and this app's) writable on a fresh install, the falsification-sweep
evidence behind it, and the mechanical check that now enforces it are recorded
once, in full, in DECISIONS.md entry 8 — this entry defers to it rather than
re-deriving the same mechanism a second time.

The ORDERING is the load-bearing half: the volume and the disk-writing image ship
together. Volume-first (before the writing image) declares storage nothing uses;
image-first (before the volume) resets the operator's data on every update until
the volume lands. So both move in one release.

**Revisit if.** umbrelOS changes where app-data lives or how it is preserved
across updates (verify against its source, not by observing a deployment), or the
app's container-side data directory moves off `/data`.

---

## 7. Operator runtime configuration is read from a data-volume env file the operator creates, never committed here

**Statement.** Per-install runtime configuration whose value is environment- or
operator-specific — first and foremost `MINER_FLEET_SUBNETS`, the LAN range(s) to
sweep — is delivered to the container via
`env_file: [{ path: ${APP_DATA_DIR}/data/config.env, required: false }]` on the
`server` service. The file is created BY THE OPERATOR on the box, inside the
persistent data volume. This repo commits the `env_file` REFERENCE only; it never
commits a real subnet, IP, hostname, MAC, or any other environment-specific value.

**Why.** This repo is PUBLIC and umbreld clones it unauthenticated, so a real LAN
range in any committed file is a codespace RULE #1 leak. The value must therefore
come from the box — and it must SURVIVE app updates, or the operator re-enters it
every release. Three facts force this exact shape:

- The app reads `MINER_FLEET_SUBNETS` from its process environment
  (miner-fleet `src/config/runtimeConfig.ts`), and when it is unset auto-derives
  the range from the container's own address — which on Umbrel is the docker
  app-network, not the operator's LAN, so the fleet is empty until it is set.
- umbreld passes a community-app compose NO `--env-file` and exports no custom
  vars (`getumbrel/umbrel` legacy-compat/app-script — the `docker compose`
  invocation carries no `--env-file`; only `APP_DATA_DIR`/`APP_ID`-class vars are
  exported). So a value reaches the container only as a literal in this compose
  or via an `env_file` this compose names.
- A literal here either commits the range (RULE #1) or is wiped on every update,
  because umbreld replaces this compose file on update while preserving the data
  directory (entry 6).

`env_file` pointing INTO the data volume satisfies all three: `${APP_DATA_DIR}` is
interpolated by compose from umbreld's exported environment, the file lives in the
update-surviving data dir, and nothing real is committed. `required: false` lets a
fresh install with no file yet start cleanly (empty fleet) rather than failing on
a missing env file.

The long-form `env_file` entry carrying a `required:` key is a Docker Compose
Specification feature added in **Docker Compose v2.24.0 (2024-01)**. This is a hard
REQUIREMENT of the mechanism, not a nicety: an older Compose rejects the syntax and
the container fails to start on every install and update — strictly worse than the
"empty fleet until configured" state `required: false` exists to avoid. It is
stated here as a checkable requirement, NOT an assumption about what umbrelOS
bundles: current umbrelOS (1.x) ships a Docker Compose well past 2.24, and
DEPLOY.md § 6 has the operator confirm `docker compose version` ≥ 2.24 on their own
box before relying on it (the failure, if their Compose is older, is a loud
install-time parse error, not a silent empty fleet). No shipped `getumbrel/umbrel-apps`
app was found using this long-form syntax, so the version floor is asserted from
the Compose changelog, not from an in-ecosystem precedent.

This supersedes the configuration-surface approach originally scoped in `#5`'s
issue body (an in-app settings UI persisted to the volume): the shipped `0.2.0`
image has no such UI and reads configuration only from the environment, so the
env-file mechanism is what actually works against the image being released.

**Revisit if.** miner-fleet gains an in-app settings surface that persists
configuration to the data volume and reads it at runtime (at which point the
subnet moves there and this entry is reconsidered), or umbrelOS gains a native
per-app settings mechanism that survives updates, or umbreld begins passing a
persistent `--env-file` to community-app compose.

---

## 8. The app template ships `data/.gitkeep`; the bind-mount source is never created by an on-box hook

**Statement.** `pipfox-miner-fleet/data/.gitkeep` is a committed, empty file. Its
sole purpose is to force git — and, downstream, this repo's rsync-based app
template — to carry a `data/` directory alongside `docker-compose.yml`, so that
`${APP_DATA_DIR}/data` (entry 6's bind-mount source) exists, owned `1000:1000`,
before the `server` container ever starts. No on-box script, hook, or chown is
used to create or fix the ownership of this directory.

**Why.** `getumbrel/umbrel` apps.ts `install()` materialises a fresh install's
app-data directory by `rsync --archive --exclude ".gitkeep" <template>/.
<app-data-dir>` and does nothing else to it — it does not pre-create arbitrary
subdirectories, and it has no chown for this app's data path. So a subdirectory
a compose file declares as a bind-mount source exists after install if and only
if the store repo ships it inside the app template; otherwise Docker creates it
`root:root` at `compose up`, and the hardened container (uid 1000, `cap_drop:
ALL`, `no-new-privileges:true`) cannot write into it — `SQLITE_CANTOPEN`
(errcode 14), crash loop, on every fresh install. This was verified, not
assumed: a falsification sweep of `getumbrel/umbrel-apps` found 332 of 333 apps
mounting `${APP_DATA_DIR}/data` ship a committed `data/.gitkeep`, matching this
mechanism. Re-derivable method, run 2026-08-02: shallow-clone
`getumbrel/umbrel-apps`, select every app directory whose `docker-compose.yml`
declares an `${APP_DATA_DIR}/data` bind mount, and check whether that same app
directory ships a committed `data/` directory. `scripts/check-bind-mount-dirs.sh`
now enforces the invariant mechanically — this entry records the choice among
the alternatives that mechanism forecloses:

- **(a) Mount `${APP_DATA_DIR}` itself as `/data`, rather than the `data`
  subdirectory beneath it — REJECTED.** It would work: the app-data root is the
  directory umbreld itself creates and owns, so it is writable with no
  extra step. It is rejected because `${APP_DATA_DIR}` also holds
  `docker-compose.yml` and `umbrel-app.yml` — the exact files umbreld reads to
  run this app — so mounting the root exposes umbreld's own control files to a
  writable mount inside the container. A compromised container could rewrite
  its own compose file or manifest and escalate on the app's next restart. The
  `data` subdirectory carries no such file, so mounting only it keeps the
  container's write access scoped to state it actually owns.
- **(b) A `hooks/pre-start` script doing `mkdir -p` + `chown -R 1000:1000` on
  the box — REJECTED.** This is a real, shipped upstream pattern — the single
  exception in the 333-app sweep (`file-drop`) uses exactly this — and it has a
  genuine advantage a committed directory does not: it would SELF-HEAL an
  existing box already caught by this bug, where a static `data/.gitkeep`
  cannot retroactively fix a `root:root` directory Docker already created. It
  is rejected anyway because it hands umbreld a host-side script that this
  PUBLIC repo would run AS ROOT on every app start, which cuts directly against
  the hardening posture the rest of this file establishes (digest pinning,
  `cap_drop: ALL`, `no-new-privileges:true`) — for the sake of repairing an
  install base of roughly one box, which a documented one-off `chown`
  (DEPLOY.md § 4) already recovers without any code running on the box at all.

No `version` bump accompanies this fix. `data/` is not in umbreld's
`legacy-compat/app-script` update whitelist
(`UPDATE_FILES_WHITELIST_PRE`/`_POST`), so an app UPDATE never touches it —
bumping `version` would deliver nothing to an already-broken box, while also
obligating a content-identical `0.2.1` miner-fleet image re-release purely to
keep `scripts/check-version-drift.sh` green. A fresh install or a reinstall
rsyncs whatever this repo currently holds, so it gets the fix with no version
change at all; an already-broken box is repaired by the manual `chown` in
DEPLOY.md § 4, not by an update. The `chown` and a reinstall are not
equivalent-cost recoveries for a box that already has state: `chown` preserves
it, while `reinstall` runs `uninstall` first, and `uninstall` removes the whole
app-data directory (`app.ts`: `fse.remove(this.dataDirectory)`) — destroying the
inventory/telemetry SQLite history and the operator's `config.env` (entry 7)
before `install` re-creates it from the template. DEPLOY.md § 4 states this.

**Revisit if.** umbreld starts pre-creating declared bind-mount sources itself
(verify against its source, not by observing a deployment that happened to
work), or the install base grows past the point where a documented one-off
`chown` is a reasonable recovery for an already-broken box, or umbrelOS gains a
first-class per-app data-permission mechanism that makes either rejected option
above safe to adopt.

---

## 9. The `server` service's hardening is enforced mechanically, not by inspection

**Statement.** `scripts/check-compose-hardening.sh` asserts, on the `server`
service alone, that `cap_drop:` contains `ALL`, that `security_opt:` contains
`no-new-privileges:true`, that no `network_mode: host` is declared, and that no
host `ports:` are published. It runs in `.local-ci.yml`, so the push gate and CI
execute it identically. It fails closed on anything it cannot parse.

**Why.** Entries 2 and 6 already record this hardening as a decision, but a
decision recorded in prose is only checked when someone reads the file. The PR
that added this gate verified the property by inspection — every compose line it
changed was a comment, so nothing about the `server` service moved — and that
inspection covers exactly one reading of one diff. It does not survive the next
one. A later edit that drops `cap_drop:` while rewording the prose around it
produces a container that still starts, still passes the version-drift and
bind-mount gates, and silently runs with full capabilities on the operator's box.
The assertion is scoped to `server` because `app_proxy` is Umbrel's injected
reverse-proxy: a directive found there says nothing about the container that runs
the app, so a whole-file match would report safety it never established.

**Revisit if.** umbrelOS stops fronting community apps with `app_proxy` (which is
what makes a published host port unnecessary), or the app acquires a genuine need
for host networking or a retained capability. In either case entries 1, 2 or 6
change first and this gate follows them — the gate is downstream of those
decisions, never the reason to keep one.
