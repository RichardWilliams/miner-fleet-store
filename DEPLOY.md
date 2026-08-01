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

---

## 3. Release procedure

A release starts in **miner-fleet**, not here. Follow that repo's README release
section first; it ends with a mandatory artefact verification that gates this
store bump. Do not begin here.

Once miner-fleet has published `X.Y.Z` and you have verified the published
artefact resolves and is `linux/amd64`-only:

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

3. **Refresh `releaseNotes`** in `umbrel-app.yml`. This is operator-facing text
   shown in the Umbrel UI — write what changed, in plain language.

4. **Open a PR and merge it.** The merge to `main` is what publishes the release;
   umbreld polls `main`.

5. **Wait up to 5 minutes**, then confirm the Update button appears in the Umbrel
   UI and apply it.

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

**Roll back.** Set `version` and the image reference back to the previous
release's values and merge. Umbrel treats it as an update like any other. Keeping
the previous release's tag and digest in the PR description of each release bump
makes this a copy-paste rather than an archaeology exercise.

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
node:alpine `node` account), matching umbreld's `1000:1000` app-data ownership, so
the container writes there under `cap_drop: ALL` + `no-new-privileges:true` with
no root chown — do NOT relax the hardening to "fix" a write permission; a
permission failure means the uid or the mount source ownership is wrong, not that
the hardening is. (The earlier bootstrap note citing uid 1001 predated the shipped
runtime; the image was changed to 1000 precisely so this mount is writable.)

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
