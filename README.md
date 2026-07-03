<div align="center">

<img src="assets/plasma-logo.png" alt="Plasma" width="104" />

# Plasma Non-Validator Templates

**Templates and deployment configurations for running Plasma non-validator (observer) nodes.**

[![Website](https://img.shields.io/badge/website-plasma.org-14342B)](https://www.plasma.org)
![Networks](https://img.shields.io/badge/networks-mainnet%20%C2%B7%20testnet%20%C2%B7%20devnet-14342B)
![Consensus](https://img.shields.io/badge/consensus-0.15.0-14342B)
![Execution](https://img.shields.io/badge/execution-Reth%20v1.8.3-14342B)

</div>

## Contents

- [Plasma Non-Validator Templates](#plasma-non-validator-templates)
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

## Networks

| Network | Chain ID | Consensus | Execution   | GHCR Auth Required |
| ------- | -------- | --------- | ----------- | ------------------ |
| mainnet | 9745     | 0.15.0    | Reth v1.8.3 | No                 |
| testnet | 9746     | 0.15.0    | Reth v1.8.3 | No                 |
| devnet  | 9747     | 0.15.0    | Reth v1.8.3 | No                 |

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

# Optional: Verify
docker compose ps
docker compose logs -f consensus
# Optional: Start monitoring, Grafana available at http://localhost:3000
docker compose -f monitoring/compose.yml -d
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
    ├── .env                  # Configure network, images, tags, snapshots, trusted peers
    ├── non-validator.toml    # Consensus config, including this network's bootstrap nodes
    ├── genesis.json          # Chain genesis
    ├── keys/                 # BLS12-381 validator public keys
    └── identities/           # Validator identity files
```

## Configuration

Each network's config lives under `config/{network}/`. The `.env` holds the network name, the image
versions and tags, the snapshot directory (`SNAPSHOT_DIRECTORY`), and the execution trusted-peers
list (`EXECUTION_TRUSTED_PEERS`); `non-validator.toml` holds the consensus configuration including
that network's bootstrap nodes. One shared `compose.yml` serves all networks. The validator keys,
identities, and genesis stay as files because the consensus client (0.15.0) reads them from disk.

> Execution peers are passed to reth on the command line via
> `EXECUTION_TRUSTED_PEERS`, but consensus bootstrap nodes live in
> `non-validator.toml`: consensus 0.15.0 has no CLI/env option for them, so they
> must be in the config file the observer reads.

### Consensus Configuration

Each network has its own `config/{network}/non-validator.toml`. The files are
identical apart from the per-network `[network.bootstrap_nodes.*]` entries.

Key sections:

| Section                       | Fields                                                                                       | Description                       |
| ----------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------- |
| _(top-level)_                 | `engine_api_url`, `consensus_api_host`, `authrpc_jwtsecret`                                  | Execution engine connection       |
| `[persistence]`               | `data_dir`                                                                                   | Consensus data storage path       |
| `[network]`                   | `p2p_port`, `interval`, `timeout`, `identity_file_path`, `trusted_only`, `discovery.enabled` | P2P networking and peer discovery |
| `[api]`                       | `enabled`, `host`, `port`                                                                    | Consensus API endpoint            |
| `[validators.*]`              | `validator_keystore_pk_file_path`, `identity_file_path`                                      | Validator committee               |
| `[network.bootstrap_nodes.*]` | `api_host`, `p2p_port`, `peer_id`                                                            | Consensus bootstrap peers         |

### Peer Discovery

The checked-in templates use `plasma-consensus-public:0.15.0` with peer discovery enabled. External
addresses can be configured for nodes behind NAT:

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

> :warning: Mainnet uses the default ports. In order to avoid collisions when running multiple nodes
> on the same host, testnet and devnet use different ports.

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
> Transferring from an EC2 instance **in the same region** is free. Running your node in
> `us-east-2` is the most cost-effective option.

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

If a snapshot exists, the compose stack imports it **automatically**. The `initialize-consensus`
and `initialize-execution` services import the newest `*-backup-*.tar.gz` they find in
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

Restore consensus as `/consensus/data.mdb`, preserving the node identity files:

```bash
docker run --rm --user 0:0 --entrypoint /bin/bash \
  -v "${NETWORK}_consensus-data:/consensus" \
  -v "$BACKUP_DIR:/backups:ro" \
  ghcr.io/plasmalaboratories/plasma-consensus-public:0.15.0 \
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
  ghcr.io/paradigmxyz/reth:v1.8.3 \
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

---
