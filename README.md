<div align="center">

<img src="assets/plasma-logo.png" alt="Plasma" width="104" />

# Plasma Node Templates

**Templates and deployment configurations for validator and non-validator Plasma nodes.**

[![Website](https://img.shields.io/badge/website-plasma.org-14342B)](https://www.plasma.org)
![Networks](https://img.shields.io/badge/networks-mainnet%20%C2%B7%20testnet%20%C2%B7%20devnet-14342B)
![Consensus](https://img.shields.io/badge/consensus-1.1.0-14342B)
![Execution](https://img.shields.io/badge/execution-Reth%20v1.11.3-14342B)

</div>

## Contents

- [Plasma Node Templates](#plasma-node-templates)
  - [Contents](#contents)
  - [Networks](#networks)
  - [Quick Start](#quick-start)
  - [Directory Structure](#directory-structure)
  - [Configuration](#configuration)
    - [Consensus Configuration](#consensus-configuration)
    - [Execution Engine URL](#execution-engine-url)
    - [Peer Discovery](#peer-discovery)
    - [Ports](#ports)
  - [Usage](#usage)
    - [Node troubleshooting](#node-troubleshooting)
      - [Sync Issues](#sync-issues)
      - [Engine API unreachable (consensus startup retries)](#engine-api-unreachable-consensus-startup-retries)
  - [Running a Validator](#running-a-validator)
  - [Monitoring](#monitoring)
  - [Performance](#performance)
  - [Database Snapshots (optional)](#database-snapshots-optional)
    - [Prerequisites](#prerequisites)
    - [Step 1: Download](#step-1-download)
    - [Step 2: Import snapshots](#step-2-import-snapshots)
      - [Manual snapshot import (alternative)](#manual-snapshot-import-alternative)
    - [Snapshot troubleshooting](#snapshot-troubleshooting)
      - [Access Denied](#access-denied)
      - [403 Forbidden](#403-forbidden)
      - [Empty bucket listing](#empty-bucket-listing)
      - [Wrong prefix](#wrong-prefix)
  - [Upgrading](#upgrading)

## Networks

| Network | Chain ID | Consensus | Execution    | GHCR Auth Required |
| ------- | -------- | --------- | ------------ | ------------------ |
| mainnet | 9745     | 1.1.0     | Reth v1.11.3 | No                 |
| testnet | 9746     | 1.1.0     | Reth v1.11.3 | No                 |
| devnet  | 9747     | 1.1.0     | Reth v1.11.3 | No                 |

## Quick Start

```bash
# Clone
git clone https://github.com/PlasmaLaboratories/node-templates.git
cd node-templates

# One-time: create the shared bridge network used by the nodes and monitoring
docker network create plasma
# One-time: select your network, creates a symlink .env -> config/<network>/.env
scripts/use.sh mainnet

# Start the node
docker compose up -d

# Optional: Verify via docker compose (currently used network via scripts/use.sh)
docker compose ps
docker compose logs -f consensus
docker compose logs -f execution
# Optional: Verify via docker
docker ps
docker logs -f mainnet-consensus
docker logs -f mainnet-execution
# Optional: Start monitoring, Grafana available at http://localhost:3000
docker compose -f monitoring/compose.yml up -d
# Optional: Start more nodes, devnet, testnet and mainnet nodes can coexist on the same host
scripts/use.sh testnet
docker compose up -d
```

## Directory Structure

```
compose.yml                   # Network-agnostic service definitions
.env -> config/{network}/.env # Symlink created by scripts/use.sh, git ignored to survive git pulls
monitoring/                   # Monitoring stack, compose.yml, Prometheus and Grafana resources
scripts/                      # Scripts: use.sh, download-snapshot.sh, regression.sh
config/                       # Per-network configuration and data
└── {network}/                # Networks: devnet, testnet, mainnet
    ├── .env                  # Configure network, role, images, tags, snapshots, trusted peers
    ├── non-validator.toml    # Consensus config for NODE_ROLE=observer
    ├── validator.toml        # Consensus config for NODE_ROLE=validator
    └── genesis.json          # Chain genesis
```

The `.env`'s `NODE_ROLE` value selects the config file: `non-validator.toml` or `validator.toml`.

## Configuration

Each network's configuration is under `config/{network}/`. The `.env` file holds:

- the network name
- the node role (`NODE_ROLE`)
- the image versions and tags
- the snapshot directory (`SNAPSHOT_DIRECTORY`)
- the execution trusted-peers list (`EXECUTION_TRUSTED_PEERS`)
- the optional consensus Engine API URL override (`ENGINE_API_URL`, see
  [Execution Engine URL](#execution-engine-url))

The `non-validator.toml` and `validator.toml` files hold the consensus configuration. This includes
each network's bootstrap nodes. One shared `compose.yml` serves all networks.

The schema below is for consensus version `1.1.0`. Networks on consensus version `0.15.0` use
`[validators.*]` file paths instead. See [Upgrading](#upgrading) for details.

> The command line sets execution peers, through `EXECUTION_TRUSTED_PEERS`. Consensus bootstrap
> nodes work differently: consensus version `0.15.0` has no command-line or environment-variable
> option for them. You must set them in the config file instead — `non-validator.toml` or
> `validator.toml`.

### Consensus Configuration

Each network has its own `config/{network}/non-validator.toml` file. Networks on consensus `1.1.0`
also have a `config/{network}/validator.toml` file. See [Running a Validator](#running-a-validator).

Key sections:

| Section                       | Fields                                                                                                                                 | Description                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| _(top-level)_                 | `engine_api_url`, `consensus_api_host`, `authrpc_jwtsecret`, `max_ancestry_check_depth`                                                | Execution engine and validation settings |
| `[persistence]`               | `data_dir`                                                                                                                             | Consensus data storage path              |
| `[network]`                   | `p2p_port`, `interval`, `timeout`, `identity_file_path`, `trusted_only`, `discovery.enabled`, `bootstrap_dnsaddrs`                     | P2P networking and peer discovery        |
| `[api]`                       | `enabled`, `host`, `port`                                                                                                              | Consensus API endpoint                   |
| `[chain.aquila]`              | `activation_height`, `contract_address`, `epoch_length`, `handoff_window`, `speculative_prefetch`, `unsafe_allow_short_handoff_window` | Per-network committee rotation           |
| `[chain.static_committee.*]`  | `bls_public_key`                                                                                                                       | Validator committee                      |
| `[network.bls_peer_ids]`      | `<bls_public_key>` = `<peer_id>`                                                                                                       | BLS key → peer ID mapping                |
| `[network.bootstrap_nodes.*]` | `api_host`, `p2p_port`, `peer_id`                                                                                                      | Consensus bootstrap peers                |

### Execution Engine URL

The consensus node reaches the execution node over the Engine API: `engine_api_url` in
`validator.toml` / `non-validator.toml`, default `http://<network>-execution:8551`.

That hostname is a **network alias** registered by `compose.yml` on the shared `plasma` bridge
network (`networks.plasma.aliases`), not the container name:

- Renaming or recreating the execution container keeps the `<network>-execution` alias attached,
  so the Engine URL, the JWT-authenticated connection, and the Prometheus scrapes in
  `monitoring/prometheus.yml` keep working. Container names are cosmetic on Docker networks;
  service aliases are the addressing contract.
- Run one stack per network per host. Two stacks of the same network share the `plasma` network
  and would publish the same alias, making DNS ambiguous. To run a second stack of the same
  network, isolate it on its own Docker network and set `ENGINE_API_URL` (below).

Both services mount the same `jwt-secret` volume: consensus reads `authrpc_jwtsecret
= "/jwt/jwt.hex"` from the TOML and execution starts reth with `--authrpc.jwtsecret /jwt/jwt.hex`.
The pairing must match; a renamed container does not affect this shared secret.

The compose files target Docker. When execution runs outside the stack — bare-metal host,
Kubernetes, or a remote machine — point consensus at it with `ENGINE_API_URL` in
`config/<network>/.env` (team-wide) or `config/<network>/.env.secret` (per-host, git-ignored):

```dotenv
ENGINE_API_URL="http://host.docker.internal:8551"
```

When set, consensus passes it to `plasma-cli` as `--engine-api-url`, which overrides the TOML's
`engine_api_url`; when unset or empty the TOML value applies unchanged. The override is announced
at startup with a one-line INFO; the URL value itself is never logged, since it may carry
credentials (userinfo, path, query). Reth must listen on an interface reachable from the
consensus container (`--authrpc.addr 0.0.0.0` is the compose default) and both sides must share
the same JWT secret; the compose-managed `jwt-secret` volume only covers the in-stack case.

After changing addressing, the alias, or the override, run `scripts/regression.sh`. It renders
`docker compose config` for each network and exercises the consensus entrypoint with a stubbed
`plasma-cli`; it requires `docker compose` and `python3`, and starts no containers.

### Peer Discovery

Observer templates use `plasma-consensus-public:1.1.0` with peer discovery enabled. Validator
templates use trusted peers with discovery disabled by default. You can configure an external
address for observer nodes behind NAT:

```toml
[network]
external_address = "node.example.com:34070"
```

Or via CLI:

```
--p2p.external-address node.example.com:34070
```

The port defaults to `p2p_port` if not provided.

### Ports

| Service        | Mainnet | Testnet | Devnet | Protocol | Exposed   | Description                |
| -------------- | ------- | ------- | ------ | -------- | --------- | -------------------------- |
| Execution RPC  | 8545    | 8546    | 8547   | HTTP     | Localhost | User-facing JSON-RPC API   |
| Execution Auth | 8551    | 8551    | 8551   | HTTP     | No        | Engine API (internal only) |
| Execution P2P  | 30303   | 30304   | 30305  | TCP/UDP  | Yes       | Execution layer peering    |
| Consensus API  | 35070   | 35070   | 35070  | HTTP     | No        | Consensus health & API     |
| Consensus P2P  | 34070   | 34071   | 34072  | TCP      | Yes       | Consensus layer peering    |
| Metrics        | 9001    | 9001    | 9001   | HTTP     | No        | Prometheus scrape target   |

> :warning: Mainnet uses the default ports. Testnet and devnet use different ports. This prevents
> port conflicts when you run multiple nodes on one host.

## Usage

Run from the repository root.

```bash
docker network create plasma # One-time: create shared docker network for nodes + monitoring
scripts/use.sh testnet # Select the network configuration (required once per clone)
docker compose up # Run a node and follow logs
docker compose -f monitoring/compose.yml up -d # Run the monitoring stack detached
docker compose logs -n 1000 -f # Display the 1000 most recent log entries and follow logs
docker compose down # Stop the node
docker compose down -v # Stop node and delete all data volumes
```

### Node troubleshooting

#### Sync Issues

Check execution client sync status:

```bash
RPC_PORT=8545 # mainnet; use 8546 for testnet or 8547 for devnet.
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  "http://localhost:${RPC_PORT}"
```

#### Engine API unreachable (consensus startup retries)

Symptom: `docker compose logs consensus` shows repeated `engine_exchangeCapabilities` retries and
the observer/validator loop never starts, while the execution container itself looks healthy.

1. Confirm the Engine URL resolves from inside the consensus container:

   ```bash
   docker compose exec consensus \
     bash -c 'exec 3<>/dev/tcp/mainnet-execution/8551' && echo reachable
   ```

   Use the hostname from `engine_api_url` (or `ENGINE_API_URL`) for your network.

2. If it does not resolve, check that execution is running and carries the alias:
   `docker compose ps`, then
   `docker inspect --format '{{json .NetworkSettings.Networks.plasma.Aliases}}' <container>`.
   If containers were renamed outside `compose.yml`, recreate the pair so the alias from the
   compose file is attached again: `docker compose up -d --force-recreate execution consensus`.
3. If it resolves but retries continue, verify the JWT secret pairing (a mismatch shows up as
   401s from reth's auth endpoint):
   `docker compose exec consensus sha256sum /jwt/jwt.hex` and
   `docker compose exec execution sha256sum /jwt/jwt.hex` must agree.
4. Running execution outside the stack (host, Kubernetes, remote)? Set `ENGINE_API_URL` per
   [Execution Engine URL](#execution-engine-url) instead of relying on Docker DNS.

## Running a Validator

You can run a validator on **devnet**, **testnet**, and **mainnet**. All three use consensus
`1.1.0`. You need coordination from the Plasma team to do this.

Running `plasma-cli node` with your own keystore does not automatically add you to the active
validator set. If you're interested in your node being enrolled as an active validator, please contact the Plasma team.

1. **Generate a validator keystore.** Use
   [ethstaker-deposit-cli](https://github.com/ethstaker/ethstaker-deposit-cli) to generate a BLS12-381 keystore and password.

   Run it via Docker, pinned to the `v1.3.0` image by digest rather than a mutable tag:

   ```bash
   mkdir -p ./keys
   docker run --rm -it \
     -v "$(pwd)/keys:/keys" \
     ghcr.io/ethstaker/ethstaker-deposit-cli@sha256:45ce887f0fdc0389bfb5ad12c7ab48a5882f0f804f06f94ce2e179bc55bad4c4 \
     new-mnemonic \
     --num_validators 1 \
     --chain mainnet \
     --folder /keys
   ```

   This command writes a keystore file to
   `./keys/validator_keys/keystore-m_12381_3600_0_0_0-<timestamp>.json` on the host. That file is
   your `VALIDATOR_KEYSTORE_FILE`.

   The `deposit_data-*.json` file is not required and can be ignored.

   The `--chain` flag also has no effect on Plasma. Use `mainnet` as its value.

   You can verify the image's build attestation before you run it:

   ```bash
   gh attestation verify \
     oci://ghcr.io/ethstaker/ethstaker-deposit-cli@sha256:45ce887f0fdc0389bfb5ad12c7ab48a5882f0f804f06f94ce2e179bc55bad4c4 \
     --owner ethstaker
   ```

2. **Point the compose stack at your keystore.** In `config/{network}/.env`, set:

   ```bash
   NODE_ROLE=validator
   VALIDATOR_KEYSTORE_FILE="/absolute/path/to/your/keystore.json"
   ```

3. **Set your fee recipient.** Edit `config/{network}/validator.toml`. Replace
   `suggested_fee_recipient` with your own Plasma address. This address receives the fees from
   blocks your validator produces.

4. **Provide the keystore password without committing it.**

   ```bash
   cp config/{network}/.env.secret.example config/{network}/.env.secret
   # then edit config/{network}/.env.secret and set VALIDATOR_KEYSTORE_PASSWORD
   ```

5. **Start the node as usual.** Run `scripts/use.sh <network>` and `docker compose up -d`, from
   [Usage](#usage).

You can switch back to observer mode at any time. Set `NODE_ROLE=observer` in `.env`. Restart the
node.

## Monitoring

Monitor your node's health:

- Execution RPC (host): `http://localhost:8545` on mainnet, `http://localhost:8546` on testnet,
  or `http://localhost:8547` on devnet.
- Consensus API (Docker network only): `http://<network>-consensus:35070`. Compose does not publish
  this port to the host.
- Metrics (Docker network only): `http://<network>-execution:9001/metrics` and
  `http://<network>-consensus:9001/metrics`. Prometheus scrapes these internal endpoints by their
  stable network aliases, so renaming the containers does not break the scrapes.

## Performance

- Use SSD storage for optimal I/O
- Ensure sufficient RAM to avoid swap usage
- Monitor CPU usage during initial sync
- Consider increasing ulimits for production deployments

## Database Snapshots (optional)

Plasma publishes daily database snapshots for all networks. Snapshots let you bootstrap a new node
in hours instead of syncing from genesis, which can take days to weeks.

Each snapshot contains two files, the consensus-layer database and the execution-layer database.
They are uploaded to a _requester-pays_ S3 bucket. You need an AWS account, standard S3
data-transfer rates apply.

Each network has its own bucket. Inside it, backups are organized by snapshot source and,
optionally, database schema version. Both files of a snapshot share the same
`YYYYMMDD-HHMMSS` timestamp in their name, which is what identifies a snapshot:

```
plasma-mainnet-db-backups/
└── observer-0/
    └── v2/
        ├── consensus-backup-20260606-020000.tar.gz
        └── execution-backup-20260606-020000.tar.gz
```

For example:

```
s3://plasma-mainnet-db-backups/observer-0/v2/consensus-backup-20260606-020000.tar.gz
s3://plasma-mainnet-db-backups/observer-0/v2/execution-backup-20260606-020000.tar.gz
```

Object names sort chronologically, so the newest snapshot is always the last one in a listing.
Older snapshots may still sit under the previous `<network>/<source>/<MM-DD-YY>/` layout; the
helper script discovers snapshots by object name, so it finds both.

### Prerequisites

| Requirement | Details                                                             |
| ----------- | ------------------------------------------------------------------- |
| AWS account | Credentials configured via `aws configure` or environment variables |
| AWS CLI     | v2 recommended (`aws --version`)                                    |
| Disk space  | **Mainnet:** ~500 GB free (updated: 26 June 2026)                   |
|             | **Testnet:** ~100 GB free                                           |
|             | **Devnet:** ~100 GB free                                            |

> **Cost note:** Data transfer out from `us-east-2` is ~$0.09/GB for the first 10 TB/month.
> Transferring from an EC2 instance **in the same region** is free. Running your node in `us-east-2`
> is the most cost-effective option.

### Step 1: Download

Use the helper script for large, resumable requester-pays downloads. Fast multi-threaded downloads
with s5cmd are also supported, but are not resumable. It writes to `./config/<network>/snapshots` by
default.

```bash
NETWORK="mainnet"
scripts/download-snapshot.sh --env "$NETWORK" --latest
```

With an AWS profile:

```bash
scripts/download-snapshot.sh --env "$NETWORK" --latest --profile plasma-snapshots
```

List the available snapshots or select one by timestamp (full `YYYYMMDD-HHMMSS`, or just the
date as `YYYYMMDD` / `YYYY-MM-DD`):

```bash
scripts/download-snapshot.sh --env "$NETWORK" --list
scripts/download-snapshot.sh --env "$NETWORK" --snapshot 20260606-020000
```

When several snapshot sources publish to the same bucket, narrow the search with `--prefix`, for
example `--prefix observer-0/`.

For faster download speeds, use [s5cmd](https://github.com/peak/s5cmd)

```bash
scripts/download-snapshot.sh --env "$NETWORK" --latest --use-s5cmd # Requires s5cmd in $PATH
```

Manual AWS CLI fallback:

```bash
NETWORK="mainnet"
BUCKET="plasma-$NETWORK-db-backups"
SNAPSHOT_PREFIX="observer-0/v2/"
SNAPSHOT="20260606-020000"

aws s3 cp \
  "s3://${BUCKET}/${SNAPSHOT_PREFIX}" \
  "./config/${NETWORK}/snapshots/" \
  --recursive \
  --exclude "*" \
  --include "*-backup-${SNAPSHOT}.tar.gz" \
  --region us-east-2 \
  --request-payer requester
```

### Step 2: Import snapshots

If a snapshot exists, the compose stack imports it **automatically**. The `initialize-consensus` and
`initialize-execution` services import the newest `*-backup-*.tar.gz` they find in
`SNAPSHOT_DIRECTORY` before initializing the databases, on every `docker compose up`. When a node
database already exists (e.g. restarting an existing node), or when no snapshot is present in the
`SNAPSHOT_DIRECTORY`, the import step is skipped and the node starts normally.

> :information_source: Note:
>
> `SNAPSHOT_DIRECTORY` defaults to `./config/<network>/snapshots`, which is the same directory that
> `download-snapshot.sh` writes to. Point it elsewhere by editing `config/<network>/.env` or via the
> environment.

#### Manual snapshot import (alternative)

To restore by hand instead, e.g. into volumes managed outside this compose project, run the steps
below. Note the compose project is named after the network (`name: ${NETWORK}`), so the volumes are
`<network>_consensus-data` and `<network>_execution-data` (e.g. `mainnet_consensus-data`).

Load the selected network's pinned images and use its snapshot directory:

```bash
# Use the same network as the download step; change this to testnet or devnet as needed.
NETWORK="mainnet"
scripts/use.sh "$NETWORK"
set -a
. "./.env"
set +a
BACKUP_DIR="${BACKUP_DIR:-${SNAPSHOT_DIRECTORY}}"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
```

Restore consensus as `/consensus/data.mdb`, preserving the node identity files:

```bash
docker run --rm --user 0:0 --entrypoint /bin/bash \
  -v "${NETWORK}_consensus-data:/consensus" \
  -v "$BACKUP_DIR:/backups:ro" \
  "${CONSENSUS_IMAGE}:${CONSENSUS_TAG}" \
  -lc 'set -euo pipefail
rm -f /consensus/data.mdb /consensus/lock.mdb
tar -xzf /backups/consensus-backup-*.tar.gz -C /consensus \
  --numeric-owner --same-owner --same-permissions \
  --transform "s,^consensus-backup.*$,data.mdb,"'
```

Restore execution, preserving the local Reth discovery secret if the snapshot does not include one:

```bash
docker run --rm --user 0:0 --entrypoint /bin/bash \
  -v "${NETWORK}_execution-data:/execution" \
  -v "$BACKUP_DIR:/backups:ro" \
  "${EXECUTION_IMAGE}:${EXECUTION_TAG}" \
  -lc 'set -euo pipefail
tmp=/tmp/discovery-secret
[ -f /execution/discovery-secret ] && cp -p /execution/discovery-secret "$tmp"
find /execution -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xzf /backups/execution-backup-*.tar.gz -C /execution \
  --strip-components=1 --numeric-owner --same-owner --same-permissions
[ -f "$tmp" ] && [ ! -f /execution/discovery-secret ] && cp -p "$tmp" /execution/discovery-secret'
```

Restart and check status:

```bash
docker compose up -d
docker compose ps
```

### Snapshot troubleshooting

#### Access Denied

You must include `--request-payer requester` on every command.

#### 403 Forbidden

AWS credentials not configured, run `aws sts get-caller-identity` to verify your session is valid.

#### Empty bucket listing

Older backups are automatically cleaned up. If the bucket appears empty, a backup cycle may be in
progress, check back later.

#### Wrong prefix

`--prefix` is matched against the start of the object key. Use `<snapshot-source>/` or
`<snapshot-source>/<version>/`, for example `observer-0/` or `observer-0/v2/`. Run
`scripts/download-snapshot.sh --env <network> --list` to see the prefixes that actually exist.

## Upgrading

See [UPGRADING.md](UPGRADING.md) for moving a network to a new consensus version.

---
