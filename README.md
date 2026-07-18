# miner-fleet-store

Umbrel Community App Store for [miner-fleet](https://github.com/RichardWilliams/miner-fleet),
a self-hosted fleet manager for Bitaxe and NerdQAxe++ Bitcoin ASIC miners.

This repository is the deploy mechanism. umbrelOS clones it over plain git with
no credentials and re-polls it on a short interval, so it must stay **public**.
Publishing a new release of the app means bumping the version and image digest
here — not touching the Umbrel box.

## Status

Bootstrap only. The store manifest, the app directory, and the compose file do
not exist yet. See the open issues for planned work.

## Layout (planned)

```
umbrel-app-store.yml          store id and display name
pipfox-miner-fleet/
  umbrel-app.yml              app manifest: version, port, description
  docker-compose.yml          app_proxy + server, image pinned by tag + digest
```

Umbrel requires the app id to be prefixed with the store id, and the app
directory name to equal the app id exactly.
