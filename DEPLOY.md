# DEPLOY — operator runbook

How this store is added to umbrelOS, how updates reach the box, how a release is
cut, and what to do when one goes wrong.

**Do not paste machine-specific values into this file.** This repository is
public. Host addresses, hostnames, MAC addresses and port-scan output belong in
your terminal, never in a commit, a manifest comment, or a PR description.

---

## 1. One-time setup

Done once per Umbrel box. After this, releases reach the box without touching it.

**Mandatory operator checklist — the deploy is not live until all five pass.**

- [ ] Confirm your Docker Compose is v2.24 (Jan 2024) or newer: `docker compose version`. This app's config file uses the long-form `env_file … required: false` syntax, which older Compose cannot parse — on an older Compose the app fails to INSTALL with a compose parse error (see § 4). Current umbrelOS ships well past this.
- [ ] In the Umbrel UI, open the App Store, then the **⋯** menu → **Community App Stores**.
- [ ] Add this repository's URL: `https://github.com/RichardWilliams/miner-fleet-store`. It should be accepted without a credential prompt — the repo is public and umbreld clones it anonymously. A credential prompt means the repo visibility has regressed; stop and fix that first.
- [ ] Install **Miner Fleet** from the Pipfox store that now appears.
- [ ] Open the app and confirm its UI loads. It is served through `app_proxy` on host port **3007** — the port declared in `umbrel-app.yml`, not the container's internal 3000.

If the app installs but the UI does not load, go to § 4 Recovery. (Setting the subnet so the fleet actually populates is a separate one-time step — see § 6.)

### Prerequisite: the image must be public

umbreld pulls with no registry authentication, so a private package fails with
401. The image's source repository is private while the image itself is public —
that split is deliberate and is recorded in miner-fleet's DECISIONS.md entry 1.
A ghcr package inherits its source repo's visibility on first publish, so it is
created private and must be flipped once, manually, in the GitHub UI. miner-fleet's
README documents that step.

---

## 2. How updates actually work

umbreld re-clones every community app store on a **5-minute interval**
(`updateInterval = '5m'` in umbreld's `app-store.ts`). It compares the `version`
field in `umbrel-app.yml` against the installed version, and surfaces an **Update**
button in the Umbrel UI when they differ.

Updates are **auto-detected, manually applied**. Umbrel does not upgrade the app
behind your back — bumping `version` here makes the button appear; you decide when
to press it.

**Expect up to 5 minutes of lag.** There is no on-demand refresh button;
`getumbrel/umbrel#2083` is the open upstream request for one. If you need the box
to notice a change immediately, the community workaround is to remove the store
URL and re-add it, which forces a fresh clone.

A bumped `version` with an unchanged image digest is a no-op deployment: umbrelOS
shows an update, pulls the same bytes, and nothing changes. Both fields move
together — see § 3.

Not every change to this repo needs a `version` bump, though — only ones an
existing box needs to be told about. A store-packaging fix that a **fresh
install already picks up with no version change at all** — for example, `#8`'s
`data/.gitkeep` (DECISIONS.md entry 8): umbreld's install rsync copies whatever
this repo currently holds, so a new install gets the fix regardless of
`version` — lands in place, no bump, no image re-release. § 3's procedure is
for releases that change what an *already-installed* box is running.

---

## 3. Release procedure

A release starts in **miner-fleet**, not here. Follow that repo's README release
section first; it ends with a mandatory artefact verification that gates this
store bump. Do not begin here.

Once miner-fleet has published `X.Y.Z`, has a **GitHub Release** for `vX.Y.Z`,
and its tagged tree carries `deploy/contract.json`, the store-side procedure
starts with one command, run from a clean checkout of this repo:

```bash
bash scripts/release.sh X.Y.Z
```

It needs `docker`, `gh`, `git` and `python3` on your PATH and a `gh` that is
already authenticated. The argument is the version and only ever the version:
the script refuses a digest argument outright, because it resolves the digest
itself.

In order, it:

1. **Resolves the multi-arch index digest** from the registry — the top-level
   `Digest:` line of `docker buildx imagetools inspect`, never one of the
   indented per-platform entries under `Manifests:` (DECISIONS.md entry 4).
   Nothing is hand-carried from miner-fleet's workflow log, so this bump can be
   cut hours later from a different machine.
2. **Fetches the upstream Release body** for `vX.Y.Z`. A missing Release, an
   empty body or a `gh` failure stops the run — there is no fall-through to
   hand-written text (DECISIONS.md entry 10). A body containing markdown
   (`**`, `[text](url)`, or a leading `#`) is refused with the reason
   (DECISIONS.md entry 11).
3. **Fetches `deploy/contract.json` at tag `vX.Y.Z`** — the same version being
   pinned, never `main`.
4. **Refuses either fetched artefact if it carries a credential shape** — an AWS
   access-key ID, a GitHub token, a PEM private-key header or an `sk-` style API
   key. The refusal names the category and never the matched text, and it runs
   before anything is written, so the tree is left exactly as it was
   (DECISIONS.md entry 15).
5. **Asserts the contract against the current compose before writing anything.**
   A mismatch stops the run with the tree exactly as it was.
6. **Writes the bump**: `version` in `pipfox-miner-fleet/umbrel-app.yml`, the
   `releaseNotes` block in the same file, the image tag *and* `@sha256:` digest
   in `pipfox-miner-fleet/docker-compose.yml`, and both fetched artefacts into
   `upstream/vX.Y.Z/`, removing the previous version's directory.
7. **Re-runs every gate in `RELEASE_GATES`** — the list declared once in
   `scripts/lib/release-context.sh`, which is also the list this document's
   recovery path runs in § 3.1 step 5 — against the tree it just wrote.
8. **Commits the bump on branch `release-X.Y.Z`, and stops there.** It does not
   push and it does not open the PR. The push-time gates evaluate whatever is
   HEAD when they fire, and they fire when the driver is *invoked* — before the
   commit exists — so a push from inside it would carry a commit nothing had
   validated at its own SHA (DECISIONS.md entry 16). Re-running for the same
   version after a mid-sequence failure rewrites the same bytes and makes no
   second commit.

Then finish by hand. The driver prints each of the first two commands with this
run's own values already filled in — copy them from its output rather than
retyping them:

- **Push the branch**, with `git -C <repo> push --set-upstream <remote>
  release-X.Y.Z`. This is the step every push-time gate runs against, and it
  evaluates the commit the driver actually made.
- **Open the PR** with the `gh pr create` command the driver printed; its body is
  composed from the run that just happened, down to the gates that verified it.
  Re-running the driver once the PR is open prints the push alone and names the
  open PR instead, so a resumed release is never handed an invitation to open a
  second one.
- **Merge the PR.** The merge to `main` is what publishes the release; umbreld
  polls `main`.
- **Wait up to 5 minutes**, then confirm the Update button appears in the Umbrel
  UI and apply it.

### 3.1 Recovery path — the same bump by hand

**This is the recovery path, not the procedure.** Use it only when
`scripts/release.sh` cannot run — no `docker`, no authenticated `gh`, or a
machine without python3. It reaches the same end state by hand; the same values
have to land in the same places, and every gate in `.local-ci.yml` still has to
pass before the push.

1. **Capture the index digest.** Read the `Digest:` line from:

   ```bash
   docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z
   ```

   That top-level value is the **multi-arch index digest**. Use it. Do NOT use a
   digest from the indented `Manifests:` list below it — those are per-platform
   manifests, and umbreld resolves the index.

2. **Edit exactly two fields, in two files.** Each value lives in exactly one
   greppable place, so a release bump is a two-field edit rather than a
   search-and-replace:

   | File | Field |
   |---|---|
   | `pipfox-miner-fleet/umbrel-app.yml` | `version: "X.Y.Z"` |
   | `pipfox-miner-fleet/docker-compose.yml` | the `image:` tag **and** `@sha256:` digest |

3. **Vendor the two upstream artefacts**, replacing the previous version's
   directory so exactly one survives — the gates fail closed on a stale or
   duplicated copy:

   The upstream coordinates come from `scripts/lib/repo-context.sh`, which is
   where this repo declares them once — read them from there rather than typing
   them a second time. So does the vendored path: `vendor_rel_path` derives the
   version-encoded directory name that IS the staleness guard, and a
   hand-typed one is the single value here that could satisfy this step to the
   letter and still fail step 5. Set `version` once and let the rest follow:

   ```bash
   source scripts/lib/repo-context.sh
   version=X.Y.Z
   rm -rf "${VENDOR_REL_DIR:?}"/*/
   mkdir -p "$(vendor_rel_path "$version")"
   gh release view "v${version}" --repo "$UPSTREAM_REPO_SLUG" --json body -q .body \
     > "$(vendor_rel_path "$version" "$VENDOR_NOTES_NAME")"
   gh api -H "Accept: application/vnd.github.raw" \
     "repos/${UPSTREAM_REPO_SLUG}/contents/${UPSTREAM_CONTRACT_PATH}?ref=v${version}" \
     > "$(vendor_rel_path "$version" "$VENDOR_CONTRACT_NAME")"
   ```

   The `v${version}` in the two `gh` invocations is miner-fleet's own tag, not
   this repo's directory name, which is why it stays spelled out here.

4. **Write `releaseNotes` from the vendored body**, rather than retyping it.
   The listing is a copy of the Release, never a second original, and a
   hand-indented `>-` block is exactly where a copy goes wrong. The block indent
   comes from `$NOTES_BLOCK_INDENT`, exported by the `source` in step 3, for the
   same reason the coordinates do — it is declared once, in
   `scripts/lib/repo-context.sh`, and the drift gate re-emits at whatever that
   file says:

   ```bash
   python3 scripts/lib/manifest_data.py set-block \
     pipfox-miner-fleet/umbrel-app.yml releaseNotes \
     "$(vendor_rel_path "$version" "$VENDOR_NOTES_NAME")" "$NOTES_BLOCK_INDENT"
   ```

5. **Run the gates locally** before pushing. Which gates those are comes from
   `RELEASE_GATES` in `scripts/lib/release-context.sh` — the same declaration
   the driver reads, so this hand path is verified by exactly the set a
   driver-cut release is. That library holds the release procedure's own
   knowledge and declares no coordinate, so it is a second `source` rather than
   part of step 3's:

   ```bash
   source scripts/lib/release-context.sh
   for gate in "${RELEASE_GATES[@]}"; do
     bash "scripts/${gate}.sh"
   done
   ```

   Running them together matters: `check-release-notes-drift.sh` is the only one
   that refuses a stale second `upstream/vX.Y.Z/` directory, and
   `check-deploy-contract.sh` would go on reading the pinned one and pass.

6. **Open a PR and merge it.** The merge to `main` is what publishes the
   release; umbreld polls `main`.

7. **Wait up to 5 minutes**, then confirm the Update button appears in the
   Umbrel UI and apply it.

---

## 4. Recovery

**The app will not start after an update.** Check the app's logs in the Umbrel UI
first. The most common cause is an image reference that does not resolve — a
mistyped digest, or a digest that names a per-platform manifest instead of the
index. Verify the exact reference from the compose file:

```bash
docker buildx imagetools inspect ghcr.io/richardwilliams/miner-fleet:X.Y.Z@sha256:<digest>
```

If that fails, the reference is wrong. Correct it here and merge; the box picks
up the fix on the next poll.

**The app fails to install/start with a compose or YAML parse error** (a message
about `env_file`, an unexpected mapping, or the `required` key). Your Docker
Compose is older than v2.24 and cannot parse the long-form `env_file … required:
false` this app uses. Update umbrelOS (which bundles a current Compose) and retry;
confirm with `docker compose version` (§ 1). This is a hard, loud failure — it is
not the "app runs but the fleet is empty" case (that one is § 6).

**The pull fails with 401.** The published package has gone private. Flip it back
to public in the GitHub package settings; no store change is needed.

**The pull fails with a manifest/platform error.** The release published something
other than `linux/amd64`, or the amd64 entry is missing. This is a miner-fleet
release defect — fix it there and cut a new patch release. Do not work around it
here.

**Roll back.** Run `bash scripts/release.sh <previous-version>`, then push the
branch it prepares and merge the PR you open from it, exactly as § 3 describes.
Umbrel treats it as an update like any other. The script re-resolves that
version's digest from the registry and re-vendors that version's Release
body and contract, so the roll-back is a real, gate-checked bump rather than a
partial revert — which matters because the gates fail closed on a vendored
directory that does not name the pinned version. If the script cannot run, § 3.1
is the same roll-back by hand.

**The store URL will not add, or the app never appears.** Confirm the repo is
public and that `umbrel-app-store.yml` is at the repo root. Then confirm the app
directory name is byte-for-byte equal to the app id — a mismatch makes the app
invisible to the store scan rather than producing a diagnosable error.

**The container is running but the browser shows a gateway/proxy error.** The
app itself is fine; `app_proxy` cannot reach it. `app_proxy` resolves the
application container by the compose-generated name in its `APP_HOST` — currently
`pipfox-miner-fleet_server_1` — so renaming the `server` service, or changing the
app id without changing `APP_HOST` to match, breaks the proxy while leaving the
container up and healthy. Nothing reports this as a misconfiguration: the app
looks installed and running, and only the browser sees the failure. Check that
the compose service is still named `server` and that `APP_HOST` still reads
`<app-id>_server_1`.

**The Umbrel UI shows the app as unhealthy.** The `healthcheck` polls
`/api/health` inside the container. Note this does not by itself restart
anything — Docker's `restart:` policy does not act on health status — so an
unhealthy-but-running app stays up and must be restarted from the Umbrel UI.
Check the app's logs for why the endpoint stopped answering.

**The app crash-loops on a fresh install with a SQLite/database error in the
logs.** This is `#8`: on a box installed before this fix, `${APP_DATA_DIR}/data`
was created `root:root` at `compose up` because the store repo did not yet ship
a `data/` directory in the app template, and the container (uid 1000, `cap_drop:
ALL`) cannot write into a root-owned mount. Fix it once, manually:

```bash
sudo chown -R 1000:1000 ~/umbrel/app-data/pipfox-miner-fleet/data
```

Then restart the app from the Umbrel UI. This is a manual, one-off recovery,
not something an app update can do for you: `data/` is outside umbreld's
update whitelist (the `legacy-compat/app-script` file list that an update
actually touches never includes it), so no version of this store can push a fix
into that directory on an already-installed box — only a shell command you run
yourself can.

The `chown` above is the recovery that PRESERVES your existing state. **Do not
"fix" this by reinstalling the app instead.** `reinstall` runs `uninstall`
then `install` (`getumbrel/umbrel` `legacy-compat/app-script`), and `uninstall`
REMOVES the whole app-data directory first (`app.ts`: `fse.remove(this.dataDirectory)`)
before `install` re-creates it from the template. That does repair the
ownership — but it also destroys your discovered-miner inventory and telemetry
history, and the `config.env` subnet file you created under `data/` (§ 6,
DECISIONS.md entry 7), which you would then have to re-enter. Reinstalling is
not a costless alternative to the `chown` above.

A genuinely **fresh install** — a box that never had this app before — does not
need this step at all: umbreld's install rsync copies the app template —
including the `data/` directory this repo now ships — so `${APP_DATA_DIR}/data`
is created `1000:1000` from the start, and the app writes to it immediately.

---

## 5. Decisions and why they are not free to change

Full statements with revisit conditions are in [`DECISIONS.md`](DECISIONS.md).
Summarised here so nobody "simplifies" one without meeting its rationale.

**Bridge networking, not `network_mode: host`** (entry 2). A bridge container
already reaches LAN addresses outbound, which is what sweeping the miners' HTTP
API needs. Host networking adds only broadcast/mDNS reception — and costs the
`app_proxy` auth layer in front of the app. Do not switch to host networking to
"fix" a discovery problem without first designing an authentication path that
does not depend on `app_proxy`.

**Pinned by semver tag AND digest together** (entry 3). The digest makes the
deployment reproducible; the tag makes it legible to a human deciding whether to
accept an update. `latest`, a bare commit SHA, and a bare digest are each banned —
the first is neither reproducible nor informative, the second carries no ordering,
the third is unreadable.

**The service must be named `server`** (entry 1). `app_proxy` resolves
`APP_HOST: pipfox-miner-fleet_server_1`; the `_server_1` suffix is a hard naming
contract. Renaming the service silently breaks the proxy.

**The digest is the multi-arch INDEX digest** (entry 4), not one of the
per-platform manifest digests listed beneath it. Both are valid 64-hex digests,
so nothing about the syntax tells them apart and no check catches the wrong one —
a per-platform digest deploys correctly right up until the release that changes
the index, then breaks with no diff to explain it. § 3 step 1 names the line to
read.

**The icon URL is on `main`, deliberately unpinned** (entry 5). It is the one
exception to the pinning discipline above, and the reason is mechanical: the
commit SHA does not exist when the icon is authored, and squash-merge destroys
the branch SHA. Do not "fix" it to look consistent with the image pin — the two
defend against different things.

**Persistent data volume** (entry 6). From `0.2.0` the app persists its miner
inventory and telemetry to a SQLite database under `/data`, bind-mounted from
`${APP_DATA_DIR}/data`. That directory **survives app updates and is cleared only
on uninstall** (verified against `getumbrel/umbrel` app.ts: the update path never
removes the data dir; uninstall does). The image runs as **uid 1000** (the
node:alpine `node` account). What makes the mount writable is that this repo
SHIPS `pipfox-miner-fleet/data/.gitkeep` (entry 8): umbreld's fresh-install rsync
copies the app template verbatim and creates only what the template ships, owned
`1000:1000` — it does not pre-create arbitrary subdirectories on its own. Delete
that `.gitkeep` and the directory Docker creates instead at `compose up` is
`root:root`, which the hardened container cannot write into
(`scripts/check-bind-mount-dirs.sh` enforces this at push time). Do NOT relax the
hardening to "fix" a write permission; a permission failure means `data/.gitkeep`
is missing or a box needs the one-off recovery in § 4, not that the hardening is
wrong.

**Operator config lives on the box, never in this repo** (entry 7). The subnet to
sweep is read from `${APP_DATA_DIR}/data/config.env`, a file the operator creates
on the Umbrel — see § 6. This repo commits only the `env_file` reference; a real
LAN range in a committed file is a RULE #1 leak. The `env_file` path is inside the
data volume, so the setting survives updates alongside the database.

**The volume and the disk-writing image ship in the same release** (entry 6). A
release moves `umbrel-app.yml`'s `version`, the compose `image:` tag **and**
`@sha256:` index digest, AND (the first time) the volume declaration, together.
Shipping the volume before the writing image declares unused storage; shipping the
image before the volume resets data on every update. `scripts/check-version-drift.sh`
enforces the manifest-vs-compose-tag half at push time.

**`releaseNotes` is a copy of the upstream Release, never authored here**
(entry 10), and it is **plain prose with no markdown** (entry 11) because
community-store pages bypass the markdown renderer while the updates dialog does
not — the same string would look broken on one surface and fine on the other.
`scripts/check-release-notes-drift.sh` enforces the copy at push time. Do not
"improve" the listing text here; improve the Release body upstream and re-run
the release script.

**This repo asserts the compose against the upstream deployment contract, and
never generates the compose from it** (entry 12). The container port, the health
path and the data-directory mount target are facts miner-fleet owns;
`scripts/check-deploy-contract.sh` checks the compose still satisfies them at the
pinned tag. The direction is permanent — a generator would flatten the Umbrel
packaging contract and the explanatory comments this compose file carries.

**The two networked reads happen once, in the release driver** (entry 13). Both
gates above compare against artefacts vendored under `upstream/vX.Y.Z/` rather
than calling the network, so neither can fail on an unavailable network — and a
stale or missing vendored copy fails them closed.

**Four vendor-prefixed credential shapes are refused before anything is published
from this repo** (entry 15) — an AWS access-key ID, a GitHub token, a PEM
private-key header and an `sk-` style API key. They catch the likeliest
accidental paste, not every secret that could exist, so read them as four named
shapes rather than as a guarantee. The text in `releaseNotes` and the prose in
the vendored contract are written by a human in a PRIVATE repo and copied into
this PUBLIC one, where the history is permanent. `scripts/release.sh` refuses either fetched artefact before writing,
and `scripts/check-secret-leak.sh` refuses the same shapes at push time over the
files a release bump writes — the driver covers the automated path, the gate
covers the § 3.1 hand path. Neither prints the matched text. Private-range and
loopback IP literals are deliberately NOT among the refused shapes: this app
sweeps the operator's own LAN, so `192.168.x.x` in operator guidance is
necessary prose, not a leak. Do not "tighten" the gate by adding them.

---

## 6. Set your subnet on the box (one-time, required for a populated fleet)

**Do this once after installing or first-updating to `0.2.0`.** Until it is done
the dashboard loads but the fleet is EMPTY — and it fails SILENTLY, with no signal
at all: with no subnet set, discovery does not sit idle, it derives a range from
the container's OWN address and sweeps that. On Umbrel that address is the app's
Docker bridge network, not your LAN, so the sweep succeeds, finds nothing, and logs
nothing — the app logs discovery only on an actual error (no usable address at all,
a malformed range), not on a successful sweep that happened to find zero miners.
`/api/health` still returns OK and the dashboard's empty state is identical to a
real empty LAN, so `docker logs` will NOT show you the cause — the only way to tell
"wrong subnet" from "genuinely empty LAN" is the checks below. Setting the subnet is
what points it at the right network. The value is read from a file **you create on
the Umbrel**; it is never committed to this public repo (entry 7), and because the
file lives in the app's data volume it **survives every future app update** (only an
uninstall clears it).

The value belongs only on your box — do not paste your real range into a commit,
a PR, or an issue.

1. Open a shell on your Umbrel (SSH, or the Terminal app).
2. Confirm your Docker Compose is new enough for this app's config mechanism — the
   `env_file … required: false` form needs **Compose v2.24 (Jan 2024) or newer**:

   ```bash
   docker compose version
   ```

   Current umbrelOS ships well past this; if yours reports older than `v2.24`,
   update umbrelOS first (on an older Compose the app fails to start with a compose
   parse error rather than starting empty).
3. Write your real LAN range into the app's data-volume config file (replace the
   example range with yours; the directory already exists after the app's first
   run):

   ```bash
   echo 'MINER_FLEET_SUBNETS=192.168.1.0/24' \
     > ~/umbrel/app-data/pipfox-miner-fleet/data/config.env
   ```

   You can list more than one range comma-separated
   (`MINER_FLEET_SUBNETS=192.168.1.0/24,192.168.2.0/24`). The path
   `~/umbrel/app-data/pipfox-miner-fleet/data/` is the host side of the container's
   `/data` mount. If `~/umbrel` is not your install location, substitute your
   Umbrel root — `$UMBREL_ROOT/app-data/pipfox-miner-fleet/data/` — wherever that
   points on your host.
4. Restart the app from the Umbrel UI (or `Stop` then `Start`). On restart, Docker
   Compose reads `config.env` and the sweep begins; the dashboard populates within
   a poll interval (~30 s).

**If the fleet is still empty**, work through it in this order:

- **Confirm the value reached the container** (the optional check below). If it
  reports `0`, `config.env` is missing, mis-pathed, or the app was not restarted —
  a configuration problem, not a network one.
- **Confirm the range matches where your miners are.** Check a miner's IP in your
  router and make sure it falls inside the CIDR you set.
- **Confirm the container can reach your LAN.** This app relies on Docker's bridge
  network SNATing outbound traffic to your LAN — the normal case, and why no host
  networking is needed. If the value is present and the range is right but the
  fleet is still empty, an unusual router/firewall setup may be blocking the
  container's bridge subnet from reaching the LAN; that is the one failure mode
  outside this app's control. `config.env` also accepts the app's other
  `MINER_FLEET_*` tunables (poll interval, timeouts); `MINER_FLEET_SUBNETS` is the
  only one you must set.

**Optional confirmation** that Compose is reading the file (does not print your
range anywhere public):

```bash
docker inspect pipfox-miner-fleet_server_1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -c '^MINER_FLEET_SUBNETS='
```

`1` means the value reached the container; `0` means `config.env` is missing,
mis-pathed, or the app was not restarted after it was created.
