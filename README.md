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
  - [Image access and GHCR troubleshooting](#image-access-and-ghcr-troubleshooting)
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
docker compose logs -f consensus execution
# Optional: Start monitoring, Grafana available at http://localhost:3000
docker compose -f monitoring/compose.yml up -d
# Optional: Start more nodes, devnet, testnet and mainnet nodes can coexist on the same host
scripts/use.sh testnet
docker compose up -d
```

## Image access and GHCR troubleshooting

The default images can be pulled without a GitHub account or registry login:

| Image | Access |
| --- | --- |
| `ghcr.io/plasmalaboratories/plasma-consensus-public` | Public distribution of the consensus client; used by these templates. |
| `ghcr.io/plasmalaboratories/plasma-consensus` | Private package; requires credentials with package read access. |
| `ghcr.io/paradigmxyz/reth` | Public image of the open-source Reth client; used by these templates. |

For a permission error, first check the image path and tag, including any Compose overrides.
Use the `plasma-consensus-public` package for public deployments. A private package's permissions
do not apply to the separate public package.

Expired or stale GHCR credentials can prevent a public pull. Log out of GHCR and retry the
selected stack's images:

```bash
docker logout ghcr.io
docker compose pull
```

Logging out removes saved GHCR credentials; private packages will require login again.
If the error persists, temporarily move Docker's client configuration aside. This also removes
its credential-helper settings, selected context, and other client preferences from use, so
record `docker context show` first. The following Bash commands create a unique private backup
directory instead of overwriting an existing `config.json.bak`:

```bash
(
  set -eu
  docker_config_dir="${DOCKER_CONFIG:-$HOME/.docker}"
  test -f "$docker_config_dir/config.json"
  backup_dir=$(mktemp -d "$docker_config_dir/config-backup.XXXXXX")
  mv "$docker_config_dir/config.json" "$backup_dir/config.json"
  printf 'Docker configuration saved to %s/config.json\n' "$backup_dir"
)
```

Retry `docker compose pull` against the intended Docker context. To restore the configuration,
move `config.json` from the printed backup directory to its original location, preserving any
newly created configuration first. Moving the file does not delete credentials from an external
credential store. Never paste its contents into an issue or commit it to Git.

## Directory Structure

```
compose.yml                   # Network-agnostic service definitions
compose.external-engine.yml   # Optional override for execution outside this stack
.env -> config/{network}/.env # Symlink created by scripts/use.sh, git ignored to survive git pulls
monitoring/                   # Monitoring stack, compose.yml, Prometheus and Grafana resources
scripts/                      # Scripts: use.sh, download-snapshot.sh, regression.sh
config/                       # Per-network configuration and data
└── {network}/                # One directory per network
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

Consensus reads `engine_api_url` from the role's TOML file. Its default is
`http://<network>-execution:8551`. Compose registers `<network>-execution` and
`<network>-consensus` as DNS aliases on the shared `plasma` network. These aliases survive
container renames and match the targets in `monitoring/prometheus/prometheus.yml`.
Recreating containers through this Compose configuration also attaches the aliases.
A custom or parameterized `container_name` therefore does not require an Engine URL change.
For example, save this as `compose.names.yml`:

```yaml
services:
  execution:
    container_name: ${NODE_LABEL:?Set NODE_LABEL}-execution
  consensus:
    container_name: ${NODE_LABEL:?Set NODE_LABEL}-consensus
```

Apply it after selecting the chain with `scripts/use.sh <network>`:

```bash
export NODE_LABEL=exchange-node
export COMPOSE_FILE=compose.yml:compose.names.yml
docker compose up -d
```

Keep the same override selected for subsequent Compose commands. Keep the `execution` and
`consensus` service keys, their `plasma` network membership, and their `<network>-execution`
and `<network>-consensus` aliases. Use service-based commands such as
`docker compose logs execution` and `docker compose exec consensus <command>` in operator scripts
so those scripts also survive container renames. `NETWORK` selects the chain and its configuration;
do not change it merely to label a deployment. `NODE_LABEL` in this example changes only the
two container names.

These aliases prevent the Engine DNS failure caused by renaming a container. Overrides that
remove the aliases or disconnect the services from the shared network can still break connectivity.
External execution needs a reachable explicit URL as described below. The aliases also preserve
the default Prometheus DNS targets; custom tooling that uses container names needs its own update.

Run one stack per network per Docker host. Two stacks for the same network would publish
identical aliases on `plasma`, making DNS ambiguous. Separate stacks require distinct Docker
networks, project names, container names, and published ports; this template does not configure
that layout.

To override the TOML URL, add `ENGINE_API_URL` to `config/<network>/.env.secret`:

```dotenv
ENGINE_API_URL="http://host.docker.internal:8551"
```

`host.docker.internal` resolves to the host on Docker Desktop. On Linux, configure a reachable
host address or a Compose `extra_hosts` mapping to `host-gateway`.

Compose loads the value into the consensus container through `env_file`. A value in
`.env.secret` takes precedence over one in `config/<network>/.env`. Exporting the variable in
the host shell alone does not pass it to this container. Compose does not substitute variables
inside the mounted TOML files.

When the value is nonempty, the entrypoint passes it as `plasma-cli --engine-api-url`, overriding
`engine_api_url`. When it is unset or empty, the default stack uses the TOML value. The entrypoint
logs a generic message announcing the override without printing its value. The URL remains
visible in process arguments and container metadata, so restrict host and Docker access.
Keep credential-bearing URLs in the git-ignored `.env.secret`; the network `.env` and TOML
files are tracked in Git.

For execution running outside this stack, select `compose.external-engine.yml`. From the
repository root, after selecting a network with `scripts/use.sh <network>`:

```bash
export COMPOSE_FILE=compose.yml:compose.external-engine.yml
docker compose up -d
```

This starts consensus and its initialization services. The local execution services are assigned
a disabled profile and skipped. Leave `COMPOSE_PROFILES` unset and do not enable the
`external-engine` profile. This mode requires a nonempty `ENGINE_API_URL`; the entrypoint exits
with an error before starting `plasma-cli` if it is missing.

If switching an existing stack to external execution, first stop its local execution services
using the base configuration:

```bash
docker compose -f compose.yml stop execution initialize-execution
```

Selecting the override does not stop containers that are already running. The default Prometheus
execution target will be down when local execution is stopped; configure the external engine's
metrics target separately. To return to local execution, remove `ENGINE_API_URL` from the network
env files, ensure the TOML points at `<network>-execution:8551`, unset `COMPOSE_FILE`, and run
`docker compose up -d`.

Both nodes must use the same JWT secret. The default stack mounts `jwt-secret` at `/jwt` in both
containers. Consensus uses `authrpc_jwtsecret = "/jwt/jwt.hex"`; reth uses
`--authrpc.jwtsecret /jwt/jwt.hex`. For an external engine, provision a matching secret before
starting consensus, or copy the generated secret securely to the external host. For example,
after `initialize-openssl` has completed, save the selected network's secret to a private file:

```bash
(umask 077; docker compose run --rm --no-deps --entrypoint /bin/sh initialize-openssl \
  -c 'cat /jwt/jwt.hex' > /secure/path/jwt.hex)
```

Create the destination directory first and replace `/secure/path/jwt.hex` with a private path.
Do not commit or share this file. Configure the external reth to read it and listen on an address
reachable from consensus. Restrict Engine API access to the consensus node. The external reth
also needs the matching `config/<network>/genesis.json` or a database snapshot; see
[Database Snapshots](#database-snapshots-optional).

Run `scripts/regression.sh` after changing Engine addressing. It renders both Compose modes for
all networks and exercises the entrypoint with a stubbed `plasma-cli`. It requires Docker Compose
v2.24+ and Python 3, uses a temporary fixture, and starts no containers.

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
```

### Node troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for startup errors, stalled sync, failed snapshot
imports, and recovery checks. Deployment agents should also read [AGENTS.md](AGENTS.md).

#### Sync Issues

See [sync checks](TROUBLESHOOTING.md#healthy-container-stalled-chain) for chain identity,
progress samples, and finality comparisons. TCP health and `eth_syncing` alone do not establish
that the node has reached the network head.

#### Engine API unreachable (consensus startup retries)

See [Engine API troubleshooting](TROUBLESHOOTING.md#engine-api-unreachable) for DNS, TCP,
JWT, and external-engine checks.

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

For Reth storage v2, use the [Reth v2 migration guide](RETH-V2-MIGRATION.md) and select v2 on
[Plasma Snapshots](https://snapshots.plasma.to/index.html). The instructions below describe the
requester-pays S3 download path; they do not select the portal's Reth v2 manifests.

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

Keep only one matching snapshot pair in the import directory. Each initializer chooses its
archive independently, so a directory containing several runs can select mismatched state.
A failed extraction can leave database markers that cause a retry to skip restore; see
[snapshot import troubleshooting](TROUBLESHOOTING.md#snapshot-import-and-reth-v2).

If a snapshot exists, the compose stack imports it **automatically**. The `initialize-consensus` and
`initialize-execution` services select `consensus-*.tar.gz` and `execution-*.tar.gz` respectively
from `SNAPSHOT_DIRECTORY`, taking the last filename in sorted order. They restore before
initializing the databases on `docker compose up`. When a node
database already exists (e.g. restarting an existing node), or when no snapshot is present in the
`SNAPSHOT_DIRECTORY`, the import step is skipped and the node starts normally.

> :information_source: Note:
>
> `SNAPSHOT_DIRECTORY` defaults to `./config/<network>/snapshots`, which is the same directory that
> `download-snapshot.sh` writes to. Point it elsewhere by editing `config/<network>/.env` or via the
> environment.

#### Manual snapshot import (alternative)

Stop both clients and retain consistent backups before restoring by hand. The commands below
replace database contents in place; use the [v2 migration guide](RETH-V2-MIGRATION.md) for an
observer migration using new volumes. The default Compose project is named after the network
(`name: ${NETWORK}`), so the volumes are
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

See [UPGRADING.md](UPGRADING.md) for the consensus `0.15.0` to `1.1.0` upgrade.
The [Reth v2 migration guide](RETH-V2-MIGRATION.md) covers replacing an observer's databases
with a matching v2 snapshot pair.

---
