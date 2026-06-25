# Plasma Non-Validator Templates

Templates and deployment configurations for running Plasma non-validator (observer) nodes.

## Networks

| Network | Chain ID | Consensus Image           | Consensus Version | Execution Version | Bootstrap Nodes             | GHCR Auth Required |
| ------- | -------- | ------------------------- | ----------------- | ----------------- | --------------------------- | ------------------ |
| mainnet | 9745     | `plasma-consensus-public` | 0.15.0            | Reth v1.8.3       | 16 consensus + 16 execution | No                 |
| testnet | 9746     | `plasma-consensus-public` | 0.15.0            | Reth v1.8.3       | 16 consensus + 16 execution | No                 |
| devnet  | 9747     | `plasma-consensus-public` | 0.15.0            | Reth v1.8.3       | 3 consensus + 3 execution   | No                 |

## Quick Start

```bash
# Clone
git clone https://github.com/PlasmaLaboratories/non-validator-templates.git
cd non-validator-templates

# No GHCR login is required; `plasma-consensus-public` is publicly accessible

# Start a node (replace {network} with mainnet, testnet, or devnet)
cd {network}/docker-compose
docker compose up -d

# Optional: start monitoring (Prometheus + Grafana)
docker compose -f monitoring.yml up -d

# Verify
docker compose ps
docker compose logs -f plasma-consensus
```

## Directory Structure

```
{network}/
├── docker-compose/
│   ├── docker-compose.yml        # Service definitions
│   ├── .env                      # Image versions and tags (source of truth)
│   ├── non-validator.toml        # Consensus configuration
│   ├── enodes.txt                # Execution bootstrap nodes
│   ├── monitoring.yml            # Monitoring stack
│   └── monitoring/               # Prometheus & Grafana configs
└── shared/                       # Validator keys & identities (read-only)
    ├── keys/                     # BLS12-381 validator public keys
    └── identities/               # Validator identity files
```

## Configuration

All version numbers and image tags are defined in each network's `.env` file — that is the single source of truth. See `{network}/docker-compose/.env` for current values.

### Consensus Configuration (`non-validator.toml`)

Each network's `non-validator.toml` configures the consensus client. Key sections:

| Section                       | Fields                                                                                       | Description                       |
| ----------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------- |
| _(top-level)_                 | `engine_api_url`, `consensus_api_host`, `authrpc_jwtsecret`                                  | Execution engine connection       |
| `[persistence]`               | `data_dir`                                                                                   | Consensus data storage path       |
| `[network]`                   | `p2p_port`, `interval`, `timeout`, `identity_file_path`, `trusted_only`, `discovery.enabled` | P2P networking and peer discovery |
| `[api]`                       | `enabled`, `host`, `port`                                                                    | Consensus API endpoint            |
| `[validators.*]`              | `validator_keystore_pk_file_path`, `identity_file_path`                                      | Validator committee               |
| `[network.bootstrap_nodes.*]` | `api_host`, `p2p_port`, `peer_id`                                                            | Consensus bootstrap peers         |

### Peer Discovery

The checked-in templates use `plasma-consensus-public:0.15.0` with peer discovery enabled. External addresses can be configured for nodes behind NAT:

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

| Service        | Port  | Protocol | Description                   |
| -------------- | ----- | -------- | ----------------------------- |
| Execution RPC  | 8545  | HTTP     | JSON-RPC API endpoint         |
| Execution Auth | 8551  | HTTP     | Engine API (internal)         |
| Execution P2P  | 30303 | TCP/UDP  | Peer-to-peer networking       |
| Consensus API  | 35070 | HTTP     | Consensus Health/API endpoint |
| Consensus P2P  | 34070 | TCP      | Consensus networking          |
| Metrics        | 9001  | HTTP     | Prometheus metrics            |

## Usage

```bash
cd {network}/docker-compose

docker compose up -d                              # Start
docker compose -f monitoring.yml up -d            # Start monitoring
docker compose logs -f                            # Logs
docker compose down                               # Stop
docker compose -f monitoring.yml down             # Stop monitoring
docker compose down -v && docker compose up -d    # Clean restart
```

## Troubleshooting

### Container Startup Failures

```bash
docker compose logs <service-name>
```

### Image Pull Issues

```bash
# GHCR authentication is not required for `plasma-consensus-public`
docker pull ghcr.io/plasmalaboratories/plasma-consensus-public:0.15.0
```

### Sync Issues

```bash
# Check execution client sync status
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

## Database Snapshots

Plasma publishes daily database snapshots for **mainnet** and **testnet**. Snapshots let you bootstrap a new node in hours instead of syncing from genesis (which can take days to weeks).

Each snapshot contains two files — the consensus-layer database and the execution-layer database — uploaded to a requester-pays S3 bucket. You need an AWS account; standard S3 data-transfer rates apply.

### Prerequisites

| Requirement | Details                                                                |
| ----------- | ---------------------------------------------------------------------- |
| AWS account | Credentials configured via `aws configure` or environment variables    |
| AWS CLI     | v2 recommended (`aws --version`)                                       |
| Disk space  | **Mainnet:** ~400 GB free &nbsp;&bull;&nbsp; **Testnet:** ~100 GB free |

> **Cost note:** Data transfer out from `us-east-2` is ~$0.09/GB for the first 10 TB/month. Transferring from an EC2 instance **in the same region** is free — running your node in `us-east-2` is the most cost-effective option.

### Snapshot Buckets

| Property           | Mainnet                             | Testnet                             |
| ------------------ | ----------------------------------- | ----------------------------------- |
| **Bucket**         | `plasma-mainnet-db-backups`         | `plasma-testnet-db-backups`         |
| **Prefix format**  | `mainnet/<snapshot-source>/<date>/` | `testnet/<snapshot-source>/<date>/` |
| **Current source** | `observer-0`                        | `observer-0`                        |
| **Region**         | `us-east-2` (Ohio)                  | `us-east-2` (Ohio)                  |
| **Access model**   | Requester-pays                      | Requester-pays                      |
| **Backup cadence** | Daily                               | Daily at 02:00 UTC                  |
| **Transport**      | TLS required                        | TLS required                        |

### Bucket Contents

Backups are organized by network, snapshot source, and date (`MM-DD-YY`):

```
plasma-mainnet-db-backups/
└── mainnet/
    └── observer-0/
        └── 06-06-26/
            ├── consensus-backup-20260606-020000.tar.gz
            └── execution-backup-20260606-020000.tar.gz
```

| File                               | Description                                         |
| ---------------------------------- | --------------------------------------------------- |
| **Consensus database**             | Consensus-layer database snapshot                   |
| **Execution database** (`.tar.gz`) | Tar archive of the reth execution `data/` directory |

### Step 1 — Download

Use the helper script for large, restartable requester-pays downloads. It writes to `./backups/<network>` by default.

```bash
NETWORK="mainnet"              # mainnet or testnet
SNAPSHOT_SOURCE="observer-0"   # upstream snapshot producer

scripts/download-snapshot.sh \
  --env "$NETWORK" \
  --prefix "$NETWORK/$SNAPSHOT_SOURCE/" \
  --latest
```

With an AWS profile:

```bash
scripts/download-snapshot.sh \
  --env "$NETWORK" \
  --prefix "$NETWORK/$SNAPSHOT_SOURCE/" \
  --latest \
  --profile plasma-snapshots
```

List or select a specific date:

```bash
scripts/download-snapshot.sh --env "$NETWORK" --prefix "$NETWORK/$SNAPSHOT_SOURCE/" --list
scripts/download-snapshot.sh --env "$NETWORK" --prefix "$NETWORK/$SNAPSHOT_SOURCE/" --folder 06-06-26
```

Manual AWS CLI fallback:

```bash
BUCKET="plasma-$NETWORK-db-backups"
DATE="06-06-26"

aws s3 cp \
  "s3://${BUCKET}/${NETWORK}/${SNAPSHOT_SOURCE}/${DATE}/" \
  "./backups/${NETWORK}/" \
  --recursive \
  --region us-east-2 \
  --request-payer requester
```

### Step 2 — Import snapshots (optional)

The compose stack imports snapshots **automatically**. Two one-shot services
`import-consensus-snapshot` and `import-execution-snapshot` run before the node on every
`docker compose up` and import the newest `*-backup-*.tar.gz` they find in `SNAPSHOT_DIR`.
They are safe to leave enabled: each one no-ops when the database already exists or when no snapshot
is present, so a node with a populated database or an empty `SNAPSHOT_DIR` starts normally.

`SNAPSHOT_DIR` defaults to `../../backups/<network>` (resolved from
`<network>/docker-compose`) — the same `backups/<network>` directory that
`download-snapshot.sh` writes to. Point it elsewhere by editing `.env` or via the
environment.

```bash
NETWORK="mainnet"
cd "$NETWORK/docker-compose"

# Fresh node: download (Step 1) then bring the stack up, import runs first.
docker compose up -d
```

> The `import-*-snapshot` services use the consensus/execution images and tags from `.env`,
> so they always match the node binaries that read the imported database.

#### Manual import (alternative)

To restore by hand instead, e.g. into volumes managed outside this compose project, run the steps
below. Note the compose project is named after the network (`name: ${NETWORK}`), so the volumes are
`<network>_consensus-data` and `<network>_execution-data` (e.g. `mainnet_consensus-data`).

```bash
NETWORK="mainnet"
cd "$NETWORK/docker-compose"
docker compose down
BACKUP_DIR="$(cd "../../backups/$NETWORK" && pwd)"
```

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

### Snapshot Troubleshooting

| Issue                | Cause / Fix                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `Access Denied`      | You must include `--request-payer requester` on every command. The bucket rejects requests without it.                         |
| `403 Forbidden`      | AWS credentials not configured. Run `aws sts get-caller-identity` to verify you have a valid session.                          |
| Empty bucket listing | Older backups are automatically cleaned up. If the bucket appears empty, a backup cycle may be in progress — check back later. |
| Wrong prefix         | Use `<network>/<snapshot-source>/<date>/`, for example `mainnet/observer-0/06-06-26/`.                                         |

---
