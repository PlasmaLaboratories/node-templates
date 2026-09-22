# Troubleshooting a Plasma node

Run commands from the repository root with the network and Compose overrides used to deploy
the node. Start with read-only checks; keep the databases and identities while diagnosing a failure.

## Identify the deployment

```bash
docker context show
readlink .env
docker compose version
docker compose config --quiet
docker compose config --images
docker compose ps -a
docker compose logs --tail 100 initialize-openssl initialize-consensus initialize-execution execution consensus
```

The templates require Docker Compose v2.24+. Check which `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`,
`COMPOSE_PROFILES`, and `NETWORK` values your shell or service manager supplies. Shell values can
override `.env` interpolation. A different Docker context, project, or override can show an empty
stack or select different volumes. Keep migration and naming overrides selected on every restart.
Review logs locally before sharing; full `docker compose config` and container inspection output
can contain secrets.

## Startup and image pulls

| Symptom | What to check or try |
| --- | --- |
| GHCR `unauthorized` or `denied` | Check the package path and tag. `plasma-consensus` is private; `plasma-consensus-public` and the template's Reth image are public. Follow [GHCR troubleshooting](README.md#image-access-and-ghcr-troubleshooting) for stale credentials. |
| External network `plasma` not found | On the intended Docker context, create it once with `docker network create plasma`. |
| Container name conflict or port already allocated | Identify the existing stack first. Renaming alone does not isolate another same-chain stack. Check its aliases, ports, and volumes. See [container naming](README.md#execution-engine-url). |
| Initializer exited with code 0 | Expected for these one-shot services. Inspect its logs to distinguish snapshot import, fresh initialization, and skipped restore. |
| A dependency failed to start | Inspect the failed initializer's exit code and logs before restarting dependents. Check disk space, mounts, image compatibility, and archive integrity. |
| `requires a subcommand but one was not provided` or invalid config schema | Check `NODE_ROLE` and use the configuration schema for the selected consensus release. See [UPGRADING.md](UPGRADING.md). |
| External mode rejects a missing Engine URL, or unexpectedly starts local execution | Follow the [external-engine configuration](README.md#execution-engine-url). Set the URL in the network env file, leave `COMPOSE_PROFILES` unset, and do not enable the `external-engine` profile. Selecting this override does not stop old execution containers. |

## Engine API unreachable

Symptom: `docker compose logs consensus` shows repeated `engine_exchangeCapabilities` retries and
the observer/validator loop never starts, while the execution container itself looks healthy.

1. Check DNS resolution and TCP connectivity from inside the consensus container:

   ```bash
   docker compose exec consensus \
     bash -c 'exec 3<>/dev/tcp/mainnet-execution/8551' && echo reachable
   ```

   Use the hostname and port from `engine_api_url` (or `ENGINE_API_URL`). This checks TCP
   reachability; it does not authenticate an Engine API request.

2. For an in-stack engine, if the check fails, verify that execution is running and carries the alias:
   `docker compose ps`, then
   `docker inspect --format '{{json .NetworkSettings.Networks.plasma.Aliases}}' "$(docker compose ps -q execution)"`.
   If existing containers lack the alias, recreate the pair to apply the Compose configuration: `docker compose up -d --force-recreate execution consensus`.
3. If TCP connectivity succeeds but retries continue, verify the JWT secret pairing (a mismatch shows up as
   401s from reth's auth endpoint):
   `docker compose exec consensus sha256sum /jwt/jwt.hex` and
   `docker compose exec execution sha256sum /jwt/jwt.hex` must agree. For an external engine, compare against its configured JWT file.
4. Running execution outside the stack (host, Kubernetes, remote)? Set `ENGINE_API_URL` per
   [Execution Engine URL](README.md#execution-engine-url) instead of relying on Docker DNS.

An HTTP 401 from an unauthenticated Engine request is expected. It proves the HTTP endpoint
answered; it does not prove consensus has the correct JWT. Compare secrets locally without
publishing their values. Check both hosts' clocks if an external engine rejects a matching JWT.

## Healthy container, stalled chain

The execution healthcheck opens TCP ports 8545 and 8551. It does not verify JWT authentication,
chain identity, finality, or synchronization. `eth_syncing: false` alone also does not establish
that the node has reached the network head.

Use the selected network's local RPC port to sample chain identity and head:

```bash
RPC_PORT=8545 # mainnet; use 8546 for testnet or 8547 for devnet.
for method in eth_chainId eth_syncing eth_blockNumber; do
  curl --fail --silent --show-error -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[],\"id\":1}" \
    "http://127.0.0.1:${RPC_PORT}"
  printf '\n'
done
```

Expected chain IDs are mainnet `9745` (`0x2611`), testnet `9746` (`0x2612`), and devnet `9747`
(`0x2613`). Sample again after 20 seconds, inspect consensus progress, and compare block height,
timestamps, and execution hashes at matching finalized heights with a trusted node on that chain.
If the chain ID is wrong, stop and check the selected configuration and volumes before proceeding.

The devnet rehearsal logged intermittent `bytes remaining on stream` peer errors while still
catching up and finalizing. That observation does not make every occurrence harmless. If progress
stops or the errors persist, collect bounded logs and check peer reachability, client versions,
and the selected network's bootstrap configuration. See [Peer Discovery](README.md#peer-discovery).

## Snapshot import and Reth v2

Use the [observer migration guide](RETH-V2-MIGRATION.md) for paired v2 snapshots from
[Plasma Snapshots](https://snapshots.plasma.to/index.html). The legacy S3 downloader and its
requester-pays errors are covered in [snapshot troubleshooting](README.md#snapshot-troubleshooting).

| Symptom | What to check or try |
| --- | --- |
| `failed to decode committee snapshot: missing field speculative_prefetch` | Consensus v1.1.0 could not read the tested devnet v2 snapshot. Select a snapshot-compatible consensus image for both its initializer and runtime service. The migration guide records the successful devnet versions and limits. |
| Restore is skipped despite selecting a snapshot | Consensus skips restore when `data.mdb` exists; execution skips it when `db/` exists. Verify the actual mounted volumes. A successful `docker volume create` can reuse a populated volume. |
| Import failed, then a retry skips restore | An interrupted extraction can leave those same marker files. Stop and inspect the failed import; retries do not prove database completeness. After correcting the cause, use verified empty replacement volumes and retain the old pair. |
| Restore did not produce `data.mdb` or `db/` | Inspect archive layout and checksum. Do not rename arbitrary contents to bypass the check. The migration guide describes the expected archive members. |
| Checksum mismatch, truncated archive, or expired download | Keep one manifest and one matching timestamped pair. Do not mix resumed downloads from changing `latest` aliases. If the run has expired, select a new complete pair in a new directory. |
| No space left on device | Allow for compressed archives, expanded databases, and retained old volumes. Check both host storage and the Docker VM's disk capacity on Docker Desktop. Compressed size is not the import space requirement. |
| Node identity changed after import | A snapshot can contain an execution `discovery-secret`. Restore the stopped node's saved identity before startup; preserve consensus identity files and the shared JWT volume as described in the migration guide. |
| Reth 2.x starts but still uses storage v1 | A binary upgrade does not convert an existing v1 database. Check startup storage settings and follow the v2 snapshot replacement procedure when storage v2 is required. |

## Recovery and reporting

Avoid `docker compose down -v` during diagnosis: it deletes the stack's managed volumes,
including databases and generated secrets. Stop services before any manual database import and
retain a consistent backup. The v2 migration guide uses new volumes and records the rollback path;
never try to roll back by opening a v2 database with an old image. Validators require a coordinated
procedure that preserves signing safety.

For a support report, include the network and role, OS/architecture, Compose version, client
image digests, selected override filenames, snapshot timestamp (if used), service exit status,
exact error text, and two timed progress samples. Redact credentials, private keys, JWT contents,
and credential-bearing URLs. State which checks passed and which were not run.
