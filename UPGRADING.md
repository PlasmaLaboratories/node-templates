# Upgrading from plasma-consensus 0.15.0 to 1.1.0

These instructions cover the normal upgrade path. Upgrade networks independently, completing all
steps for one network before repeating them for another.

`1.1.0` requires the role argument on `plasma-cli init` and the current TOML configuration schema.
Use the matching `config/<network>/` templates as the source of truth.

## 1. Update `.env`

In `config/<network>/.env`, replace the image/version settings with the current target pins and set
the node role. Use `validator` for a validator node and `observer` for an observer node:

```dotenv
OPEN_SSL_TAG=3.5.8@sha256:61cec9c1f221755bf995f1f309211b222164599e2d1943b666f878ef644d3a0e
CONSENSUS_TAG=1.1.0@sha256:f8d7aa0c63d0188e466a86d76cf24a7d378108e997ad9ae79d8e19eb8ab4d06b
EXECUTION_TAG=v1.11.3@sha256:523e5c6a7ce69e80dc004d9ba9d276e22c35f141671f9847709256bb411cd336
NODE_ROLE=observer
```

`NODE_ROLE` selects the matching config when a new consensus database is initialized.

## 2. Update the consensus config

Update the role-specific file (`non-validator.toml` for observers or `validator.toml` for validators).
The same schema changes apply to both current templates.

### Bootstrap nodes

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

### Static committee

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

### Aquila activation

Copy the complete `[chain.aquila]` section from the matching network and role template. It is
required by the current 1.1.0 templates on devnet, testnet, and mainnet; do not copy activation
values from another network.

Once nothing references `/node/keys/*` or `/node/identities/*`, those directories can be deleted.

## 3. Replace the old consensus database and restart

The `1.1.0` consensus database is not compatible with the `0.15.0` database. Stop the selected
network, make or retain a backup of its data, and remove only the consensus volume. Do not use
`docker compose down -v` here: that also removes the execution database and generated secrets.

If a compatible consensus snapshot is present in `SNAPSHOT_DIRECTORY`, the next `docker compose up`
will restore it automatically. Otherwise, the node initializes a new consensus database and syncs
from genesis.

```bash
NETWORK="mainnet" # change to testnet or devnet as needed
scripts/use.sh "$NETWORK"
docker compose down
docker volume rm "${NETWORK}_consensus-data"
docker compose up -d
docker compose logs initialize-consensus   # exit 0, no "Invalid config schema" error
```

## Errors

- `requires a subcommand but one was not provided` → set `NODE_ROLE` (above).
- `Invalid config schema: ... is not of type "object"` → an array-of-tables section still needs
  converting to an indexed table (above).
- An Aquila activation or committee mismatch → copy `[chain.aquila]` and the committee sections
  from the matching network template; activation values are network-specific.

Networks upgrade independently. After upgrading a network to `1.1.0`, do not downgrade its data
volume to `0.15.0`; the current database format is not backwards compatible.
