# testnet snapshots

Drop downloaded Plasma **testnet** database snapshot tarballs here:

- `consensus-*.tar.gz`
- `execution-*.tar.gz`

`scripts/download-snapshot.sh --env testnet --latest` writes to this directory by
default, and the compose stack imports the newest archives it finds here on
`docker compose up` (via `SNAPSHOT_DIRECTORY` in `config/testnet/.env`).

The tarballs are multi-GB and git-ignored; only this placeholder is tracked.
