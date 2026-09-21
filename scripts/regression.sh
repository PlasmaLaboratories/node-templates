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
#      --engine-api-url only when set; when unset the TOML default applies (no flag),
#      runtime logging announces the override without ever echoing the URL value
#      (checked against a synthetic credential-bearing URL).
#   4. External execution engine mode (compose.external-engine.yml): local execution
#      services leave the model, consensus's dependency on them becomes optional, and
#      the default all-in-one render keeps its hard health gate.
#
# Static/behavioral only: renders `docker compose config` and runs the consensus entrypoint
# script with a stubbed plasma-cli. No containers are started and no state is modified.
#
# Requires: docker compose v2.24+ (compose.yml uses the long env_file syntax), python3.
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

render() { # render <network> [extra compose file] -> JSON on stdout; stderr kept for diagnostics
  local net="$1" extra="${2:-}"
  local -a args=(-f "$root/compose.yml" --project-directory "$root" --env-file "$root/config/$net/.env")
  [ -n "$extra" ] && args+=(-f "$extra")
  docker compose "${args[@]}" config --format json 2>"$tmp/render-stderr.log"
}
render_error() { head -n 1 "$tmp/render-stderr.log" 2>/dev/null || true; }

for net in "${networks[@]}"; do
  echo "== $net =="
  json="$tmp/$net.json"
  render "$net" >"$json" || { fail "$net: docker compose config did not render: $(render_error)"; continue; }

  # 1. Default render: aliases, container names, TOML/alias coupling, monitoring targets,
  #    and the env_file plumbing that delivers ENGINE_API_URL into the container.
  python3 - "$json" "$net" "$root" <<'PY' || failures=$((failures + 1))
import json, re, sys

json_path, net, root = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(json_path))
errors = []

def check(cond, msg):
    if not cond:
        errors.append(msg)

ex, co = cfg["services"]["execution"], cfg["services"]["consensus"]
ex_plasma = (ex.get("networks") or {}).get("plasma") or {}
co_plasma = (co.get("networks") or {}).get("plasma") or {}
check(ex_plasma.get("aliases") == [f"{net}-execution"],
      f"execution aliases != [{net}-execution]: {ex_plasma.get('aliases')}")
check(co_plasma.get("aliases") == [f"{net}-consensus"],
      f"consensus aliases != [{net}-consensus]: {co_plasma.get('aliases')}")
check(ex["container_name"] == f"{net}-execution", f"execution container_name: {ex['container_name']}")
check(co["container_name"] == f"{net}-consensus", f"consensus container_name: {co['container_name']}")
# env_file values from config/<net>/.env must reach the consensus container environment.
check((co.get("environment") or {}).get("NETWORK") == net,
      f"consensus environment lacks NETWORK={net} (env_file plumbing broken?)")

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
check("engine_args+=(--engine-api-url" in cmd,
      "consensus command lacks --engine-api-url forwarding")

if errors:
    for e in errors:
        print(f"FAIL: {net}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: {net}: aliases, container names, TOML coupling, prometheus targets, override guard")
PY

  # 1b. env_file plumbing for the optional .env.secret: a marker ENGINE_API_URL in the
  #     git-ignored config/<net>/.env.secret must surface in the rendered consensus
  #     environment (env_file, not interpolation, is the delivery path). Skipped when a
  #     real .env.secret exists so user files are never touched.
  secret_env="$root/config/$net/.env.secret"
  if [ -f "$secret_env" ]; then
    echo "SKIP: $net: .env.secret exists; env_file probe skipped (user file untouched)"
  else
    printf 'ENGINE_API_URL=http://plumbing-probe:8551\n' >"$secret_env"
    if render "$net" >"$tmp/$net-envprobe.json"; then
      python3 - "$tmp/$net-envprobe.json" "$net" <<'PY' || failures=$((failures + 1))
import json, sys

co, net = json.load(open(sys.argv[1]))["services"]["consensus"], sys.argv[2]
value = (co.get("environment") or {}).get("ENGINE_API_URL")
if value == "http://plumbing-probe:8551":
    print(f"PASS: {net}: ENGINE_API_URL from .env.secret reaches the consensus environment")
else:
    print(f"FAIL: {net}: .env.secret ENGINE_API_URL not in consensus environment: {value!r}", file=sys.stderr)
    sys.exit(1)
PY
    else
      fail "$net: env_file probe render failed: $(render_error)"
    fi
    rm -f "$secret_env"
  fi

  # 2. Renamed-container simulation: aliases survive a container_name override.
  override="$tmp/rename-$net.yml"
  cat >"$override" <<YAML
services:
  execution:
    container_name: ${net}-execution-renamed
  consensus:
    container_name: ${net}-consensus-renamed
YAML
  render "$net" "$override" >"$tmp/$net-renamed.json" || { fail "$net: rename render failed: $(render_error)"; continue; }
  python3 - "$tmp/$net-renamed.json" "$net" <<'PY' || failures=$((failures + 1))
import json, sys

cfg, net = json.load(open(sys.argv[1])), sys.argv[2]
ex, co = cfg["services"]["execution"], cfg["services"]["consensus"]
errors = []
if ex["container_name"] != f"{net}-execution-renamed":
    errors.append(f"rename not applied: {ex['container_name']}")
if co["container_name"] != f"{net}-consensus-renamed":
    errors.append(f"rename not applied: {co['container_name']}")
ex_plasma = (ex.get("networks") or {}).get("plasma") or {}
co_plasma = (co.get("networks") or {}).get("plasma") or {}
if ex_plasma.get("aliases") != [f"{net}-execution"]:
    errors.append(f"execution alias lost after rename: {ex_plasma.get('aliases')}")
if co_plasma.get("aliases") != [f"{net}-consensus"]:
    errors.append(f"consensus alias lost after rename: {co_plasma.get('aliases')}")
if errors:
    for e in errors:
        print(f"FAIL: {net}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: {net}: aliases survive container rename")
PY

  # 3. Entrypoint behavior with a stubbed plasma-cli (default / observer+override / validator+override).
  # The stub writes plasma-cli's argv one element per line to $PLASMA_CLI_ARGV_FILE; the
  # entrypoint's own stdout and stderr are captured to separate files. Argv assertions read the
  # argv file, leak assertions scan BOTH runtime streams, so neither can be confused with the
  # other and a leak to either stream is caught.
  python3 - "$json" "$tmp/entrypoint.sh" <<'PY'
import json, sys
cmd = json.load(open(sys.argv[1]))["services"]["consensus"]["command"][0]
# compose escapes $ as $$ inside the command; the container receives single $.
open(sys.argv[2], "w").write(cmd.replace("$$", "$"))
PY
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/plasma-cli" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  printf '%s\n' "$a" >>"${PLASMA_CLI_ARGV_FILE:-/dev/null}"
done
STUB
  chmod +x "$tmp/bin/plasma-cli"

  argv_log="$tmp/plasma-cli-argv.log"
  stdout_log="$tmp/runtime-stdout.log"
  stderr_log="$tmp/runtime-stderr.log"

  ep() { # ep <role> <ENGINE_API_URL>: argv -> $argv_log, entrypoint stdout/stderr -> $stdout_log/$stderr_log
    : >"$argv_log"
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME=/nonexistent NODE_ROLE="$1" ENGINE_API_URL="$2" \
      PLASMA_CLI_ARGV_FILE="$argv_log" \
      bash "$tmp/entrypoint.sh" >"$stdout_log" 2>"$stderr_log"
  }

  argv_pair() { # argv_pair <flag> <value>: the argv element <value> directly follows <flag>
    awk -v f="$1" -v v="$2" 'NR > 1 && prev == f && $0 == v { found = 1 } { prev = $0 } END { exit !found }' "$argv_log"
  }

  # Synthetic credential-bearing URL: each secret component (and the host) doubles as a
  # leak sentinel; the URL is allowed to appear only in the argv file.
  cred_url="http://engineuser:enginepass@override.example:8551/secretpath?qtoken=secretq#secretfrag"
  sentinels=(engineuser enginepass override.example secretpath secretq secretfrag)

  leak_scan() { # leak_scan <context>: fail if any sentinel reaches the runtime stdout/stderr logs
    local context="$1" leaked=""
    for sentinel in "${sentinels[@]}"; do
      if grep -q "$sentinel" "$stdout_log" "$stderr_log" 2>/dev/null; then
        leaked+=" $sentinel"
      fi
    done
    [ -z "$leaked" ] \
      && pass "$net: $context: runtime logging carries no URL host/userinfo/path/query/fragment" \
      || fail "$net: $context: runtime logging leaks URL secrets:$leaked"
  }

  # 3a. Default: no override flag, and no override log line.
  ep observer "" || fail "$net: entrypoint (observer, default) exited non-zero"
  argv_pair --config-path /tmp/non-validator.toml \
    && pass "$net: observer default uses non-validator.toml" \
    || fail "$net: observer default missing --config-path /tmp/non-validator.toml"
  if grep -qxF -- "--engine-api-url" "$argv_log"; then
    fail "$net: observer default passed --engine-api-url (TOML behavior not preserved)"
  else
    pass "$net: observer default passes no --engine-api-url"
  fi
  if grep -q "overriding TOML engine_api_url" "$stdout_log" "$stderr_log" 2>/dev/null; then
    fail "$net: override logged although ENGINE_API_URL is unset"
  else
    pass "$net: no override log line when ENGINE_API_URL is unset"
  fi

  # 3b. Observer + credential-bearing override: exact URL as one argv element, nothing secret
  #     in either runtime stream.
  ep observer "$cred_url" || fail "$net: entrypoint (observer, override) exited non-zero"
  argv_pair --engine-api-url "$cred_url" \
    && pass "$net: exact ENGINE_API_URL (credentials included) reaches plasma-cli argv verbatim" \
    || fail "$net: ENGINE_API_URL override not passed to plasma-cli as a single verbatim argument"
  grep -q "ENGINE_API_URL is set; overriding TOML engine_api_url" "$stderr_log" \
    && pass "$net: override announced at runtime (generic INFO, no value)" \
    || fail "$net: override applied without a runtime INFO line"
  leak_scan "observer override"

  # 3c. Validator role: role args intact, override still forwarded verbatim.
  ep validator "http://override:8551" || fail "$net: entrypoint (validator, override) exited non-zero"
  argv_pair --vote-fanout one \
    && pass "$net: validator role keeps --vote-fanout one" \
    || fail "$net: validator role lost --vote-fanout one"
  argv_pair --engine-api-url http://override:8551 \
    && pass "$net: validator role honors ENGINE_API_URL override" \
    || fail "$net: validator role lost ENGINE_API_URL override"
  argv_pair --config-path /tmp/validator.toml \
    && pass "$net: validator role uses validator.toml" \
    || fail "$net: validator role missing --config-path /tmp/validator.toml"

  # 3d. External-engine fail-fast: EXTERNAL_ENGINE=1 with no ENGINE_API_URL must exit non-zero
  #     before invoking plasma-cli, with a clear generic ERROR line (no URL value involved).
  : >"$argv_log"
  if env -i PATH="$tmp/bin:/usr/bin:/bin" HOME=/nonexistent NODE_ROLE=observer EXTERNAL_ENGINE=1 ENGINE_API_URL= \
      PLASMA_CLI_ARGV_FILE="$argv_log" \
      bash "$tmp/entrypoint.sh" >"$stdout_log" 2>"$stderr_log"; then
    fail "$net: external mode without ENGINE_API_URL did not fail fast"
  else
    pass "$net: external mode without ENGINE_API_URL fails fast"
  fi
  if [ -s "$argv_log" ]; then
    fail "$net: external fail-fast still invoked plasma-cli"
  else
    pass "$net: external fail-fast happens before any plasma-cli call"
  fi
  grep -q "ERROR EXTERNAL_ENGINE is set but ENGINE_API_URL is empty" "$stderr_log" \
    && pass "$net: fail-fast reason logged (generic, no URL value)" \
    || fail "$net: fail-fast missing the clear ERROR log line"

  # 3e. External-engine mode with ENGINE_API_URL set: starts normally with the override.
  : >"$argv_log"
  env -i PATH="$tmp/bin:/usr/bin:/bin" HOME=/nonexistent NODE_ROLE=observer \
    ENGINE_API_URL="http://external:8551" EXTERNAL_ENGINE=1 PLASMA_CLI_ARGV_FILE="$argv_log" \
    bash "$tmp/entrypoint.sh" >"$stdout_log" 2>"$stderr_log" \
    || fail "$net: external mode with ENGINE_API_URL exited non-zero"
  argv_pair --engine-api-url http://external:8551 \
    && pass "$net: external mode forwards ENGINE_API_URL normally" \
    || fail "$net: external mode did not forward ENGINE_API_URL"

  # 4. External execution engine mode: local execution services leave the model, consensus's
  #    dependency on them becomes optional, and consensus itself is unchanged. The default
  #    render must keep its hard health gate and no profiles.
  render "$net" "$root/compose.external-engine.yml" >"$tmp/$net-external.json" \
    || { fail "$net: external-mode render failed: $(render_error)"; continue; }
  python3 - "$tmp/$net-external.json" "$tmp/$net.json" "$net" <<'PY' || failures=$((failures + 1))
import json, sys

ext, default, net = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
errors = []

def check(cond, msg):
    if not cond:
        errors.append(msg)

svc = ext["services"]
check("execution" not in svc and "initialize-execution" not in svc,
      f"external model still contains local execution services: {sorted(svc)}")
check({"consensus", "initialize-consensus", "initialize-openssl"} <= set(svc),
      f"external model missing the consensus chain: {sorted(svc)}")
dep = svc["consensus"]["depends_on"]["execution"]
check(dep.get("required") is False and dep.get("condition") == "service_healthy",
      f"external consensus depends_on execution not relaxed: {dep}")
check(svc["consensus"]["depends_on"]["initialize-consensus"].get("condition")
      == "service_completed_successfully",
      "external mode lost the initialize-consensus dependency")
check(svc["consensus"]["networks"]["plasma"]["aliases"] == [f"{net}-consensus"],
      "external mode lost the consensus alias")
check("engine_args+=(--engine-api-url" in svc["consensus"]["command"][0],
      "external mode lost ENGINE_API_URL forwarding")
check((svc["consensus"].get("environment") or {}).get("EXTERNAL_ENGINE") == "1",
      "external mode missing the EXTERNAL_ENGINE marker")

# Initialization/JWT chain must survive: initialize-openssl generates the JWT secret into the
# shared jwt-secret volume; consensus reads it from the same volume. Rendered volumes are
# objects, so compare on the mount target.
def vol_targets(service):
    return [v.get("target", "") for v in (service.get("volumes") or []) if isinstance(v, dict)]

check("/jwt" in vol_targets(svc.get("initialize-openssl") or {}),
      "external mode lost the jwt-secret mount on initialize-openssl")
check("/jwt" in vol_targets(svc["consensus"]),
      "external mode lost the jwt-secret mount on consensus")
check((svc["initialize-consensus"].get("depends_on") or {}).get("initialize-openssl", {}).get("condition")
      == "service_completed_successfully",
      "external mode lost the openssl -> consensus ordering")

ddep = default["services"]["consensus"]["depends_on"]["execution"]
check(ddep.get("required", True) is True and ddep.get("condition") == "service_healthy",
      f"default consensus depends_on execution changed: {ddep}")
check((default["services"]["execution"].get("profiles") or []) == [],
      "default mode gained profiles on execution")
if errors:
    for e in errors:
        print(f"FAIL: {net}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: {net}: external-engine mode excludes local execution; default gating unchanged")
PY
done

# 5. Monitoring stack still renders.
docker compose -f "$root/monitoring/compose.yml" --project-directory "$root/monitoring" config >/dev/null 2>&1 \
  && pass "monitoring compose renders" || fail "monitoring compose does not render"

echo
if [ "$failures" -gt 0 ]; then
  echo "RESULT: $failures failure(s)" >&2
  exit 1
fi
echo "RESULT: all checks passed"
