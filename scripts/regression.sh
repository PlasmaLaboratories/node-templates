#!/usr/bin/env bash
set -euo pipefail

# Regression checks for consensus Engine API addressing (see README, "Execution Engine URL").
#
# Covers:
#   1. Stable per-network aliases (<network>-execution / <network>-consensus) on the shared
#      `plasma` network, matching the hosts used by the TOML engine_api_url and the
#      monitoring/prometheus.yml scrape targets.
#   2. Alias stability across container renames (rendered with a container_name override).
#   3. Consensus entrypoint behavior: ENGINE_API_URL is passed to plasma-cli as
#      --engine-api-url only when set; when unset the TOML default applies (no flag).
#
# Static/behavioral only: renders `docker compose config` and runs the consensus entrypoint
# script with a stubbed plasma-cli. No containers are started and no state is modified.
#
# Requires: docker compose (v2+), python3.
#
# Usage:
#   scripts/regression.sh [network ...]   # default: mainnet testnet devnet

usage() {
  echo "Usage: scripts/regression.sh [mainnet|testnet|devnet ...]" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    mainnet|testnet|devnet) ;;
    *) usage ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
networks=("$@")
[ ${#networks[@]} -eq 0 ] && networks=(mainnet testnet devnet)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

render() { # render <network> [extra compose file] -> JSON on stdout
  local net="$1" extra="${2:-}"
  local -a args=(-f "$root/compose.yml" --project-directory "$root" --env-file "$root/config/$net/.env")
  [ -n "$extra" ] && args+=(-f "$extra")
  docker compose "${args[@]}" config --format json 2>/dev/null
}

for net in "${networks[@]}"; do
  echo "== $net =="
  json="$tmp/$net.json"
  render "$net" >"$json" || { fail "$net: docker compose config did not render"; continue; }

  # 1. Default render: aliases, container names, TOML/alias coupling, monitoring targets.
  python3 - "$json" "$net" "$root" <<'PY' || failures=$((failures + 1))
import json, re, sys

json_path, net, root = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(json_path))
errors = []

def check(cond, msg):
    if not cond:
        errors.append(msg)

ex, co = cfg["services"]["execution"], cfg["services"]["consensus"]
check(ex["networks"]["plasma"]["aliases"] == [f"{net}-execution"],
      f"execution aliases != [{net}-execution]: {ex['networks']['plasma'].get('aliases')}")
check(co["networks"]["plasma"]["aliases"] == [f"{net}-consensus"],
      f"consensus aliases != [{net}-consensus]: {co['networks']['plasma'].get('aliases')}")
check(ex["container_name"] == f"{net}-execution", f"execution container_name: {ex['container_name']}")
check(co["container_name"] == f"{net}-consensus", f"consensus container_name: {co['container_name']}")

# Alias must match the engine host in every TOML (http://<net>-execution:8551).
for toml in ("validator.toml", "non-validator.toml"):
    text = open(f"{root}/config/{net}/{toml}").read()
    m = re.search(r'^engine_api_url\s*=\s*"http://([^:/"]+):(\d+)"', text, re.M)
    check(m is not None, f"{toml}: engine_api_url not found")
    if m:
        check(m.group(1) == f"{net}-execution",
              f"{toml}: engine host {m.group(1)} != alias {net}-execution")
        check(m.group(2) == "8551", f"{toml}: engine port {m.group(2)} != 8551")

# Prometheus scrapes the same aliases.
prom = open(f"{root}/monitoring/prometheus/prometheus.yml").read()
check(f"{net}-execution:9001" in prom, f"prometheus.yml missing {net}-execution:9001 target")
check(f"{net}-consensus:9001" in prom, f"prometheus.yml missing {net}-consensus:9001 target")

# Override plumbing must be present in the entrypoint (guarded, CLI-only).
cmd = co["command"][0]
check("${ENGINE_API_URL:-}" in cmd or "$ENGINE_API_URL" in cmd,
      "consensus command lacks ENGINE_API_URL guard")
check("--engine-api-url" in cmd, "consensus command lacks --engine-api-url")

if errors:
    for e in errors:
        print(f"FAIL: {net}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: {net}: aliases, container names, TOML coupling, prometheus targets, override guard")
PY
  [ $? -eq 0 ] || failures=$((failures + 1))

  # 2. Renamed-container simulation: aliases survive a container_name override.
  override="$tmp/rename-$net.yml"
  cat >"$override" <<YAML
services:
  execution:
    container_name: ${net}-execution-renamed
  consensus:
    container_name: ${net}-consensus-renamed
YAML
  render "$net" "$override" >"$tmp/$net-renamed.json" || { fail "$net: rename render failed"; continue; }
  python3 - "$tmp/$net-renamed.json" "$net" <<'PY' || failures=$((failures + 1))
import json, sys

cfg, net = json.load(open(sys.argv[1])), sys.argv[2]
ex, co = cfg["services"]["execution"], cfg["services"]["consensus"]
errors = []
if ex["container_name"] != f"{net}-execution-renamed":
    errors.append(f"rename not applied: {ex['container_name']}")
if co["container_name"] != f"{net}-consensus-renamed":
    errors.append(f"rename not applied: {co['container_name']}")
if ex["networks"]["plasma"]["aliases"] != [f"{net}-execution"]:
    errors.append(f"execution alias lost after rename: {ex['networks']['plasma'].get('aliases')}")
if co["networks"]["plasma"]["aliases"] != [f"{net}-consensus"]:
    errors.append(f"consensus alias lost after rename: {co['networks']['plasma'].get('aliases')}")
for e in errors:
    print(f"FAIL: {net}: {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
print(f"PASS: {net}: aliases survive container rename")
PY
  [ $? -eq 0 ] || failures=$((failures + 1))

  # 3. Entrypoint behavior with a stubbed plasma-cli (default / observer+override / validator+override).
  python3 - "$json" "$tmp/entrypoint.sh" <<'PY'
import json, sys
cmd = json.load(open(sys.argv[1]))["services"]["consensus"]["command"][0]
# compose escapes $ as $$ inside the command; the container receives single $.
open(sys.argv[2], "w").write(cmd.replace("$$", "$"))
PY
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nline=""\nfor a in "$@"; do line+=" $a"; done\necho "$line"\n' >"$tmp/bin/plasma-cli"
  chmod +x "$tmp/bin/plasma-cli"

  run_ep() { env -i PATH="$tmp/bin:/usr/bin:/bin" HOME=/nonexistent NODE_ROLE="$1" ENGINE_API_URL="${2-}" bash "$tmp/entrypoint.sh"; }

  out="$(run_ep observer 2>&1)" || fail "$net: entrypoint (observer, default) exited non-zero"
  grep -q -- "--config-path /tmp/non-validator.toml" <<<"$out" \
    && pass "$net: observer default uses non-validator.toml" \
    || fail "$net: observer default missing --config-path /tmp/non-validator.toml"
  if grep -q -- "--engine-api-url" <<<"$out"; then
    fail "$net: observer default passed --engine-api-url (TOML behavior not preserved)"
  else
    pass "$net: observer default passes no --engine-api-url"
  fi

  out="$(run_ep observer "http://override:8551" 2>&1)" || fail "$net: entrypoint (observer, override) exited non-zero"
  grep -q "overriding TOML engine_api_url with http://override:8551" <<<"$out" \
    && pass "$net: override is logged, not silent" \
    || fail "$net: override applied without an INFO log line"
  if grep -q -- "--engine-api-url http://override:8551" <<<"$out"; then
    pass "$net: ENGINE_API_URL override reaches plasma-cli"
  else
    fail "$net: ENGINE_API_URL override not passed to plasma-cli"
  fi

  out="$(run_ep validator "http://override:8551" 2>&1)" || fail "$net: entrypoint (validator, override) exited non-zero"
  grep -q -- "--vote-fanout one" <<<"$out" \
    && pass "$net: validator role keeps --vote-fanout one" \
    || fail "$net: validator role lost --vote-fanout one"
  grep -q -- "--engine-api-url http://override:8551" <<<"$out" \
    && pass "$net: validator role honors ENGINE_API_URL override" \
    || fail "$net: validator role lost ENGINE_API_URL override"
  grep -q -- "--config-path /tmp/validator.toml" <<<"$out" \
    && pass "$net: validator role uses validator.toml" \
    || fail "$net: validator role missing --config-path /tmp/validator.toml"
done

# 4. Monitoring stack still renders.
docker compose -f "$root/monitoring/compose.yml" --project-directory "$root/monitoring" config >/dev/null 2>&1 \
  && pass "monitoring compose renders" || fail "monitoring compose does not render"

echo
if [ "$failures" -gt 0 ]; then
  echo "RESULT: $failures failure(s)" >&2
  exit 1
fi
echo "RESULT: all checks passed"
