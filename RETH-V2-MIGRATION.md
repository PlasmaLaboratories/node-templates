# Migrating an observer to Reth storage v2

Use a matching snapshot pair from [Plasma Snapshots](https://snapshots.plasma.to/index.html)
to replace an observer's databases with Reth v2 state. Keep the existing volumes for rollback.
This procedure covers the local execution/consensus stack in `compose.yml`.

A Reth binary upgrade and a storage migration are separate operations. The
[Reth v2.0.0 release notes](https://github.com/paradigmxyz/reth/releases/tag/v2.0.0) say that
storage v2 is the default for new nodes and existing storage v1 nodes continue to work.
Changing the image tag alone therefore does not establish that a database uses storage v2.

The templates currently pin Reth v1.11.3. Before using this procedure, obtain a Plasma-approved
Reth 2.x image **with its digest**, a compatible consensus image, and confirmation that they can
read the selected snapshot pair. The snapshot manifest identifies the network and snapshot
version; it does not specify compatible client image digests. This guide does not select a
production release or change the repository's image pins.

Validators need a separate, coordinated procedure that preserves signing safety and node
identity. Do not restore an older consensus snapshot onto an active validator using this guide.

## Prepare the migration

Allow space for the compressed downloads, both extracted databases, and the retained old
volumes. The manifest's `sizeBytes` values describe compressed archives only. Confirm the
expanded size and available disk space before scheduling downtime.

Record the current image digests, Compose overrides, volume names, and node identities.
Preserve the JWT volume and any private configuration. The examples assume the default project
name, `<network>`; use the actual volume names from `docker inspect` if yours differ.

Use Bash for the commands below, from the repository root. Select an observer network with
`scripts/use.sh <network>`. Leave the external-engine override disabled and remove any
`ENGINE_API_URL` override so consensus uses its local Engine URL.

## Download one complete v2 snapshot pair

Select **v2 (reth 2.x)** on the portal. The site publishes a consensus archive and an execution
archive for each run. Download both from the same network, version, and timestamp.

| Network | Portal | v2 metadata base |
| --- | --- | --- |
| mainnet | [Mainnet snapshots](https://snapshots.plasma.to/index.html) | `https://snapshots.plasma.to/v2/` |
| testnet | [Testnet snapshots](https://testnet-snapshots.plasma.to/index.html) | `https://testnet-snapshots.plasma.to/v2/` |
| devnet | [Devnet snapshots](https://devnet-snapshots.plasma.to/index.html) | `https://devnet-snapshots.plasma.to/v2/` |

The portal's `latest` archive aliases change daily. Save the manifest once and use its timestamped
object keys so a resumed download stays on the same run. Snapshots are retained for seven days;
if a saved run expires, use a new download directory and select another complete pair.

The following downloads require `curl`, `jq`, and `sha256sum` (`shasum -a 256 -c` on macOS).
They do not stop the running node. Keep this shell open for the subsequent steps.

```bash
set -euo pipefail
export NETWORK=mainnet # or testnet/devnet; match scripts/use.sh
case "$NETWORK" in
  mainnet) SNAPSHOT_HOST=https://snapshots.plasma.to ;;
  testnet) SNAPSHOT_HOST=https://testnet-snapshots.plasma.to ;;
  devnet) SNAPSHOT_HOST=https://devnet-snapshots.plasma.to ;;
  *) exit 1 ;;
esac
export SNAPSHOT_DIRECTORY="$PWD/config/$NETWORK/snapshots/reth-v2"
mkdir -p "$SNAPSHOT_DIRECTORY"
(
  cd "$SNAPSHOT_DIRECTORY"
  if [ ! -f manifest.json ]; then
    curl -fSL "$SNAPSHOT_HOST/v2/latest/manifest.json" -o manifest.json.partial
    mv manifest.json.partial manifest.json
  fi
  jq -e --arg network "$NETWORK" '
    .network == $network and .version == "v2" and
    (.stamp | test("^[0-9]{8}-[0-9]{6}$")) and
    (. as $m | ["execution", "consensus"] | all(. as $c |
      $m.components[$c].key == ("v2/" + $c + "-" + $m.stamp + ".tar.gz") and
      ($m.components[$c].sha256 | test("^sha256:[0-9a-f]{64}$")) and
      ($m.components[$c].sizeBytes > 0)))
  ' manifest.json >/dev/null
  for component in execution consensus; do
    key=$(jq -r --arg c "$component" '.components[$c].key' manifest.json)
    digest=$(jq -r --arg c "$component" '.components[$c].sha256' manifest.json)
    file=${key##*/}
    curl -fL --retry 5 -C - "$SNAPSHOT_HOST/$key" -o "$file"
    printf '%s  %s\n' "${digest#sha256:}" "$file" | sha256sum -c -
  done
)
```

Stop if the metadata is unavailable, incomplete, or either checksum fails. The portal also
provides a `.sha256` sidecar for each archive. If `latest/manifest.json` is absent, inspect
`v2/index.json` through the portal and select a retained run with both components and checksums.
Do not substitute a v1 archive or combine runs.

Use a directory containing only this pair of archives. The current
`scripts/download-snapshot.sh` discovers legacy requester-pays S3 objects; it does not select
this portal's v2 manifests. An S3 prefix containing `v2` is not proof of Reth storage v2.

## Check the archives and target configuration

Inspect the archive member lists before importing. Execution must have one leading directory
containing its complete Reth datadir, including `db/` and any static-file or RocksDB directories.
The execution initializer strips that leading directory. The consensus initializer expects a
single database member whose name contains `consensus-` and renames it to `data.mdb`.
If the layout differs, stop and obtain matching import instructions.

The portal's mainnet archives inspected on 22 September 2026 begin with `data/` for execution
and `consensus-backup.db` for consensus. This is a partial header check, not validation of the
complete archives or their compatibility with a target release.

Existing databases make the initializers skip snapshot import. Use **new, empty volumes** for
both databases. Create an operator-owned Compose override outside the repository, for example
`$HOME/.config/plasma/reth-v2.yml`, using unique volume names:

```yaml
services:
  execution:
    image: ${RETH_V2_IMAGE:?Set the approved Reth image tag and digest}
  initialize-execution:
    image: ${RETH_V2_IMAGE:?Set the approved Reth image tag and digest}
volumes:
  execution-data:
    external: true
    name: ${RETH_V2_EXECUTION_VOLUME:?Set a new execution volume name}
  consensus-data:
    external: true
    name: ${RETH_V2_CONSENSUS_VOLUME:?Set a new consensus volume name}
```

Set `RETH_V2_IMAGE` to the full approved image reference, including `@sha256:...`. Set both
volume-name variables to new names distinct from the running stack's volumes. Export these
variables and `SNAPSHOT_DIRECTORY`. Keep a private record of the values for future restarts.
If the snapshot requires a different consensus release, apply its reviewed upgrade instructions
and pin that image for both `consensus` and `initialize-consensus` as well.

```bash
export MIGRATION_OVERRIDE="$HOME/.config/plasma/reth-v2.yml"
dc_v2() { docker compose -f compose.yml -f "$MIGRATION_OVERRIDE" "$@"; }
dc_v2 config --quiet
dc_v2 config --images
dc_v2 pull execution initialize-execution
```

Review the rendered mounts locally. Confirm both execution services use the approved image,
both database mounts point to the new volumes, and the JWT volume is unchanged. Check the
approved binaries' supported CLI flags against `compose.yml` before stopping the old node.
Do not publish rendered configuration containing secrets.

## Stop, import, and start

Stop the old stack and take consistent backups of its data and configuration. Prevent any
service manager or automation from restarting it during the migration:

```bash
docker compose -f compose.yml stop
```

Create the new database volumes only after verifying their names do not already exist.
`docker volume create` can reuse an existing volume, so its success does not prove emptiness.

Copy the stopped node's consensus identity files into the new consensus volume before running
initialization. In the default template these are `ec-secp256k1-non-validator.pem` and
`ec-secp256k1-non-validator.der`; check `identity_file_path` in your TOML for custom deployments.
Do not copy `data.mdb` or `lock.mdb`. Preserve the existing `genesis` and `jwt-secret` volumes.
Also save the old execution node's `discovery-secret` privately so you can restore its P2P
identity after importing the snapshot.

Run the initializers in order, waiting for each to finish successfully:

```bash
for initializer in initialize-openssl initialize-consensus initialize-execution; do
  dc_v2 run --rm --no-deps "$initializer"
done
```

Check the logs for a successful import of each selected archive. A message about skipping
restore because a database exists means the target volume was not empty. Stop and investigate;
do not continue with an unidentified database. Restore the saved execution `discovery-secret`
into the new execution volume, replacing any identity carried in the snapshot, before starting
reth. Confirm permissions allow the configured container user to read the restored files.

```bash
dc_v2 up -d
dc_v2 ps
dc_v2 logs --tail 100 execution consensus
```

The Compose healthcheck only checks TCP listeners. Verify the Engine JWT connection succeeds,
consensus begins processing blocks, and execution height advances toward a trusted node on the
same network. Check `eth_chainId`, `eth_syncing`, and block hashes at matching finalized heights.
Confirm the target client's startup output identifies the intended storage format. Keep the
migration override and exports in use for subsequent restarts until the deployment configuration
has been updated permanently.

## Rollback

Stop the v2 stack before changing its configuration. Restore the recorded old image pins,
configuration, and original volume mappings together. Remove the migration override and restore
the previous snapshot-directory setting before starting the old stack. Never open the imported
v2 database with the old image as a rollback method.

Keep both old databases until the new pair has passed the operational checks. Do not use
`docker compose down -v`; it can delete volumes needed for recovery. If the old database pair
can no longer catch up after the downtime, obtain a compatible recovery snapshot and coordinate
recovery with the Plasma team.
