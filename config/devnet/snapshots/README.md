# devnet snapshots

Drop downloaded Plasma **devnet** database snapshot tarballs here:

- `consensus-backup-*.tar.gz`
- `execution-backup-*.tar.gz`

`scripts/download-snapshot.sh --env devnet --latest` writes to this directory by
default, and the compose stack imports the newest archives it finds here on
`docker compose up` (via `SNAPSHOT_DIRECTORY` in `config/devnet/.env`).

The tarballs are multi-GB and git-ignored; only this placeholder is tracked.
