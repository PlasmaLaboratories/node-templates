# Upgrading to plasma-consensus 1.0.0

1.0.0 requires a role subcommand on `plasma-cli init`, and changed `non-validator.toml`'s schema.
Apply both to `config/<network>/`:

**`.env`**

```diff
-CONSENSUS_TAG=0.15.0
+CONSENSUS_TAG=1.0.0
+NODE_ROLE=observer
```

**`non-validator.toml`** — bootstrap nodes: array-of-tables → indexed table

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

**`non-validator.toml`** — `[validators.*]` (file paths) → inline committee:

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

Check the config files at `config/<network>` in this repo for the full lists


`[chain.aquila]` is only required for networks with committee rotation (currently only devnet)

Once nothing references `/node/keys/*` or `/node/identities/*`, those directories can be deleted.

## Restart and verify

```bash
scripts/use.sh <network>
docker compose down
docker compose up -d
docker compose logs initialize-consensus   # exit 0, no "Invalid config schema" error
```

## Errors

- `requires a subcommand but one was not provided` → set `NODE_ROLE` (above).
- `Invalid config schema: ... is not of type "object"` → an array-of-tables section still needs
  converting to an indexed table (above).

Networks upgrade independently — leave `.env`/`non-validator.toml` untouched to stay on 0.15.0.
