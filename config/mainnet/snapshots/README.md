# mainnet snapshots

Drop downloaded Plasma **mainnet** database snapshot tarballs here:

- `consensus-backup-*.tar.gz`
- `execution-backup-*.tar.gz`

`scripts/download-snapshot.sh --env mainnet --latest` writes to this directory by
default, and the compose stack imports the newest archives it finds here on
`docker compose up` (via `SNAPSHOT_DIRECTORY` in `config/mainnet/.env`).

The tarballs are multi-GB and git-ignored; only this placeholder is tracked.

For Reth storage v2, follow the [migration guide](../../../RETH-V2-MIGRATION.md).
It selects a matching pair from the public snapshot portal and imports into new volumes.
Keep v1 and v2 archives in separate directories.
