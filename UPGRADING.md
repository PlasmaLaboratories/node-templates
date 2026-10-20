# Upgrading

## plasma-consensus 1.1.0 → 1.2.0

Back up your data and update the image pins in `config/<network>/.env`:

```dotenv
CONSENSUS_TAG=1.2.0@sha256:1044b47600bb63ffd584bf9289c6b15de7ed5ec769bab05473a5957a1756d765
EXECUTION_TAG=v2.7.0@sha256:a7f059d470878a5a59f3c575f3fc81b536d0d2d56d7a1cbed73e717a4f766336
```

**Compatibility:** Consensus `1.1.0` can fail to read `1.2.0` committee snapshots
with `missing field speculative_prefetch`.
Use `1.2.0` with current snapshots; rollback requires a pre-upgrade backup.

```bash
NETWORK="mainnet" # or testnet/devnet
scripts/use.sh "$NETWORK"
docker compose pull
docker compose down
```

Keep volumes and secrets; do not use `docker compose down -v`.

**Reth storage:** Existing V1 databases remain supported for this upgrade, but
[Reth plans to remove V1 support](https://github.com/paradigmxyz/reth/releases/tag/v2.0.0)
in a future release; no removal date is announced. We recommend migrating to V2.
An image upgrade alone does not convert the database.
With the node stopped, use [`reth db migrate-v2`](https://reth.rs/cli/reth/db/),
or restore an observer from our [v2 snapshots](README.md#database-snapshots-optional)
into fresh database volumes, preserving identities and the JWT secret.
Download a pair with `scripts/download-snapshot.sh --env "$NETWORK" --version v2 --latest`.
Complete any storage migration before restarting:

```bash
docker compose up -d
docker compose logs --tail 100 consensus execution
```

Confirm finalized height advances after restarting.

## plasma-consensus 0.15.0 → 1.1.0

These instructions cover the normal upgrade path. Upgrade networks independently, completing all
steps for one network before repeating them for another.

`1.1.0` requires the role argument on `plasma-cli init` and the current TOML configuration schema.
Use the matching `config/<network>/` templates as the source of truth.

### 1. Update `.env`

In `config/<network>/.env`, replace the image/version settings with the current target pins and set
the node role. Use `validator` for a validator node and `observer` for an observer node:

```dotenv
OPEN_SSL_TAG=3.5.8@sha256:61cec9c1f221755bf995f1f309211b222164599e2d1943b666f878ef644d3a0e
CONSENSUS_TAG=1.1.0@sha256:f8d7aa0c63d0188e466a86d76cf24a7d378108e997ad9ae79d8e19eb8ab4d06b
EXECUTION_TAG=v1.11.3@sha256:523e5c6a7ce69e80dc004d9ba9d276e22c35f141671f9847709256bb411cd336
NODE_ROLE=observer
```

`NODE_ROLE` selects the matching config when a new consensus database is initialized.

### 2. Update the consensus config

Update the role-specific file (`non-validator.toml` for observers or `validator.toml` for validators).
The same schema changes apply to both current templates.

#### Bootstrap nodes

Convert the bootstrap node array into indexed tables:

```diff
-[[network.bootstrap_nodes]]
-api_host = "example-observer.plasmalabs.tech"
-p2p_port = 34070
-peer_id = "16Uiu2HA..."
+[network.bootstrap_nodes.0]
+api_host = "example-observer.plasmalabs.tech"
+p2p_port = 34070
+peer_id = "16Uiu2HA..."
```

#### Static committee

Replace the old file-path based validator entries with the inline committee and peer mapping:

```diff
-[validators.0]
-validator_keystore_pk_file_path = "/node/keys/bls12-381-public-key-0.hex"
-identity_file_path = "/node/identities/ec-secp256k1-validator-public-compressed-0.hex"
+[network.bls_peer_ids]
+<bls_public_key_hex_0> = "<libp2p_peer_id_0>"
+
+[chain.static_committee.0]
+bls_public_key = "<bls_public_key_hex_0>"
```

Copy the complete committee and peer lists from the matching `config/<network>/` template.

#### Aquila activation

Copy the complete `[chain.aquila]` section from the matching network and role template. It is
required by the current 1.1.0 templates on devnet, testnet, and mainnet; do not copy activation
values from another network.

Once nothing references `/node/keys/*` or `/node/identities/*`, those directories can be deleted.

### 3. Restart and migrate the consensus database

The `1.1.0` node can open and migrate the `0.15.0` consensus database in place. Make or retain a
backup before upgrading, stop the selected network, and keep its named data volumes and generated
secrets. Do not use `docker compose down -v`: it removes the execution database, consensus database,
and generated secrets.

On the first `1.1.0` start, the node migrates legacy consensus state into the current checkpoint
format. If the consensus volume is intentionally empty or has no usable database, the initializer
restores the newest consensus snapshot in `SNAPSHOT_DIRECTORY` when one is present, or initializes
a new database otherwise.

```bash
NETWORK="mainnet" # change to testnet or devnet as needed
scripts/use.sh "$NETWORK"
docker compose down
docker compose up -d
docker compose logs initialize-consensus   # exit 0; migration or initialization completed
```

### Errors

- `requires a subcommand but one was not provided` → set `NODE_ROLE` (above).
- `Invalid config schema: ... is not of type "object"` → an array-of-tables section still needs
  converting to an indexed table (above).
- An Aquila activation or committee mismatch → copy `[chain.aquila]` and the committee sections
  from the matching network template; activation values are network-specific.

Networks upgrade independently. After the `1.1.0` migration has run, do not downgrade that data
volume to `0.15.0`; rollback is not a supported general compatibility path.
