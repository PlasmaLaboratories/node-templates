# Deployment automation

This repository deploys Plasma execution and consensus clients with Docker Compose. Read the
[configuration guide](README.md), [troubleshooting guide](TROUBLESHOOTING.md), and the relevant
upgrade procedure before changing a running node:

- [Consensus upgrade](UPGRADING.md): consensus 0.15.0 to 1.1.0.
- [Reth v2 migration](RETH-V2-MIGRATION.md): observer database replacement using paired v2 snapshots.

## Identify the target

Record the Docker context, network, node role, Compose project, selected files/profiles, image
digests, and actual mounted volume names before changing state. Inspect existing services before
creating replacements. The chain is selected by `NETWORK`; do not use it as an instance label.

`scripts/use.sh` changes the checkout's shared `.env` symlink. Do not run concurrent deployments
that repoint it. Automation can use explicit `--env-file config/<network>/.env` and `-f` arguments;
check shell variables too, since exported values override env-file interpolation. Use the same
project and complete ordered override list for every command, including stop, restart, and rollback.

## Preserve state and connectivity

Keep operator configuration, keys, JWT secrets, identities, and database volumes. Do not use
`down -v`, prune volumes, or delete database files as a generic retry. Stop both clients before
manual imports and follow the selected procedure's backup and rollback steps. Stop on initializer
failure; a later skipped restore may indicate a partial import.

Use Compose service names (`execution`, `consensus`) in commands. Preserve the `plasma` network
membership and per-chain DNS aliases when overriding container names. The shared network supports
one stack per chain per host; a new project or container name alone does not isolate another stack.
External execution requires the documented override, a reachable Engine URL, and a matching JWT.

Pin compatible images for both runtime services and their initializers. Keep snapshot pairs from
the same chain, version, and timestamp. A Reth binary upgrade does not prove a storage migration.
The observer snapshot procedure does not authorize a validator restore or a second signing instance.

## Protect secrets and verify results

Do not print `.env.secret`, keystores, JWT contents, or full rendered Compose/container metadata
into shared logs. Inspect sensitive configuration locally and report only the fields needed.
Public images require no GHCR login; consult the troubleshooting guide before changing credentials.
Preserve Docker configuration if a credential reset is needed.

Before applying configuration, run `docker compose config --quiet` with the deployment's selected
files and environment. Inspect image pins and volume mappings locally. After startup, check
initializer completion, Engine authentication, chain ID, advancing head and finality, and expected
storage format. A healthy TCP listener alone is insufficient. Report validation limits explicitly.

For repository changes to Engine addressing, run `scripts/regression.sh`. It uses isolated fixtures
and starts no containers. It does not establish live sync, snapshot compatibility, or migration
success. Keep deployment-specific overrides, snapshot downloads, and credentials out of commits.
