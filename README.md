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
    - [Peer Discovery](#peer-discovery)
    - [Ports](#ports)
  - [Usage](#usage)
    - [Node troubleshooting](#node-troubleshooting)
      - [Sync Issues](#sync-issues)
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
git clone https://github.com/PlasmaLaboratories/non-validator-templates.git
cd non-validator-templates

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
scripts/                      # Scripts such as use.sh and download-snapshot.sh
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

| Section                       | Fields                                                                                       | Description                       |
| ----------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------- |
| _(top-level)_                 | `engine_api_url`, `consensus_api_host`, `authrpc_jwtsecret`                                  | Execution engine connection       |
| `[persistence]`               | `data_dir`                                                                                   | Consensus data storage path       |
| `[network]`                   | `p2p_port`, `interval`, `timeout`, `identity_file_path`, `trusted_only`, `discovery.enabled` | P2P networking and peer discovery |
| `[api]`                       | `enabled`, `host`, `port`                                                                    | Consensus API endpoint            |
| `[chain.aquila]`              | `activation_height`, `contract_address`, `epoch_length`, `handoff_window`, `speculative_prefetch` | Epoch-based committee rotation (optional; testnet and devnet only) |
| `[chain.static_committee.*]`  | `bls_public_key`                                                                             | Validator committee               |
| `[network.bls_peer_ids]`      | `<bls_public_key>` = `<peer_id>`                                                             | BLS key → peer ID mapping         |
| `[network.bootstrap_nodes.*]` | `api_host`, `p2p_port`, `peer_id`                                                            | Consensus bootstrap peers         |

### Peer Discovery

The included templates use `plasma-consensus-public:1.1.0` with peer discovery enabled. You can
configure an external address for nodes behind NAT:

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
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://localhost:8545
```

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

- Execution RPC: `http://localhost:8545`
- Consensus API: `http://localhost:35070`
- Metrics: `http://localhost:9001/metrics`

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

Backups are organized by network, snapshot source, and date (`MM-DD-YY`):

```
plasma-mainnet-db-backups/
└── mainnet/
    └── observer-0/
        └── 06-06-26/
            ├── consensus-backup-20260606-020000.tar.gz
            └── execution-backup-20260606-020000.tar.gz
```

For example:

```
s3://plasma-mainnet-db-backups/mainnet/observer-0/06-22-26/consensus-backup-20260606-020000.tar.gz
s3://plasma-mainnet-db-backups/mainnet/observer-0/06-22-26/execution-backup-20260606-020000.tar.gz
```

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

List or select a specific date:

```bash
scripts/download-snapshot.sh --env "$NETWORK" --list
scripts/download-snapshot.sh --env "$NETWORK" --folder 06-06-26
```

For faster download speeds, use [s5cmd](https://github.com/peak/s5cmd)

```bash
scripts/download-snapshot.sh --env "$NETWORK" --latest --use-s5cmd # Requires s5cmd in $PATH
```

Manual AWS CLI fallback:

```bash
NETWORK="mainnet"
BUCKET="plasma-$NETWORK-db-backups"
SNAPSHOT_SOURCE="observer-0"
DATE="06-06-26"

aws s3 cp \
  "s3://${BUCKET}/${NETWORK}/${SNAPSHOT_SOURCE}/${DATE}/" \
  "./config/${NETWORK}/snapshots/" \
  --recursive \
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

Load the selected network's pinned images:

```bash
set -a
. "./config/${NETWORK}/.env"
set +a
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

Use `<network>/<snapshot-source>/<date>/`, for example `mainnet/observer-0/06-06-26/`

## Upgrading

See [UPGRADING.md](UPGRADING.md) for moving a network to a new consensus version.

---
