#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/download-snapshot.sh --env mainnet [options]
  scripts/download-snapshot.sh --env testnet [options]
  scripts/download-snapshot.sh --env devnet [options]

Downloads public R2 v2 (Reth 2.x) snapshots by default, without AWS credentials.
Both timestamped components are checked against manifest sizes and SHA-256 digests
before they are made available for import. Partial downloads use resumable .part
files; use --snapshot with the same timestamp to resume after a newer publication.

Legacy requester-pays S3 downloads use --source s3 and restartable byte-range chunks.
An S3 snapshot is the set of <component>-backup-<YYYYMMDD-HHMMSS>.tar.gz objects
that share one timestamp under one S3 prefix, e.g.
  s3://plasma-mainnet-db-backups/observer-0/consensus-backup-20260606-020000.tar.gz
  s3://plasma-mainnet-db-backups/observer-0/execution-backup-20260606-020000.tar.gz
S3 discovery filters versioned prefixes; unversioned prefixes are treated as v1.
The legacy <network>/<source>/<MM-DD-YY>/ layout is also supported.

Options:
  --env ENV             Network environment: mainnet, testnet, or devnet.
  --source SOURCE       Snapshot backend: r2 (default) or s3.
  --version VERSION     Database snapshot version: v1 or v2 (default).
  --snapshot STAMP      Select YYYYMMDD-HHMMSS, YYYYMMDD or YYYY-MM-DD.
                        R2 dates must match exactly one complete pair.
  --latest              Select the newest snapshot (default for R2).
  --dest DIR            Destination directory. Defaults to ./config/ENV/snapshots.
  --dry-run             Show what would be downloaded without downloading archives.
  --no-gzip-test        Skip gzip validation. R2 SHA-256 verification is always enabled.
  --list                List available snapshots and exit.
  -h, --help            Show this help.

S3-only options (require --source s3):
  --bucket BUCKET       Override the environment's default S3 bucket.
  --profile PROFILE     AWS CLI profile to use. Defaults to AWS_PROFILE/default resolution.
  --region REGION       AWS region. Defaults to AWS_REGION, AWS_DEFAULT_REGION, or us-east-2.
  --prefix PREFIX       Limit discovery to a bucket prefix, e.g. observer-0/ or observer-0/v2/.
  --folder FOLDER       Select by S3 folder: a full prefix such as observer-0/v2, or a legacy
                        MM-DD-YY date folder such as 06-06-26.
  --chunk-size SIZE     Chunk size for ranged downloads. Defaults to 5GiB. Examples: 1G, 512M.
  --keep-parts          Keep part files after assembling final files.
  --use-s5cmd           Download with s5cmd, which is faster than aws s3 cli. Requires s5cmd on PATH.

Environment bucket defaults:
  mainnet: PLASMA_MAINNET_BACKUPS_BUCKET or plasma-mainnet-db-backups
  testnet: PLASMA_TESTNET_BACKUPS_BUCKET or plasma-testnet-db-backups
  devnet:  PLASMA_DEVNET_BACKUPS_BUCKET or plasma-devnet-db-backups

Examples:
  scripts/download-snapshot.sh --env mainnet --latest
  scripts/download-snapshot.sh --env testnet --list
  scripts/download-snapshot.sh --env testnet --version v1 --latest
  scripts/download-snapshot.sh --env devnet --snapshot 20261019-020000
  scripts/download-snapshot.sh --source s3 --env mainnet --latest
  scripts/download-snapshot.sh --source s3 --env mainnet --latest --profile plasma-snapshots
  scripts/download-snapshot.sh --source s3 --env mainnet --list
  scripts/download-snapshot.sh --source s3 --env mainnet --version v1 --snapshot 20260606-020000
  scripts/download-snapshot.sh --source s3 --env devnet --prefix observer-4/v2/ --latest
  scripts/download-snapshot.sh --source s3 --env mainnet --latest --use-s5cmd
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*" >&2
}

stat_size() {
  if [[ -f "$1" ]]; then
    stat -c%s "$1"
  else
    printf -- '-1\n'
  fi
}

human_bytes() {
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$1"
  else
    printf '%s bytes' "$1"
  fi
}

parse_size() {
  local input="${1^^}"
  local number unit multiplier

  if [[ ! "$input" =~ ^([0-9]+)(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB)?$ ]]; then
    die "invalid size '$1'; use an integer with optional K/M/G/T suffix"
  fi

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]:-B}"

  case "$unit" in
  B) multiplier=1 ;;
  K | KB | KIB) multiplier=1024 ;;
  M | MB | MIB) multiplier=$((1024 * 1024)) ;;
  G | GB | GIB) multiplier=$((1024 * 1024 * 1024)) ;;
  T | TB | TIB) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
  *) die "invalid size unit '$unit'" ;;
  esac

  printf '%s\n' "$((number * multiplier))"
}

trim_slashes() {
  local value="$1"
  value="${value#/}"
  value="${value%/}"
  printf '%s\n' "$value"
}

ensure_trailing_slash() {
  local value
  value="$(trim_slashes "$1")"
  if [[ -n "$value" ]]; then
    printf '%s/\n' "$value"
  else
    printf '\n'
  fi
}

# Isolate the temporary-directory cleanup trap from the S3 path.
download_r2() (
  local network="$ENVIRONMENT" dest="$DESTDIR" stamp="$SNAPSHOT"
  local host scratch component archive key digest size file
  local version_prefix=""
  [[ "$SNAPSHOT_VERSION" == v1 ]] || version_prefix="$SNAPSHOT_VERSION/"
  case "$network" in
    mainnet) host=https://snapshots.plasma.to ;;
    testnet) host=https://testnet-snapshots.plasma.to ;;
    devnet) host=https://devnet-snapshots.plasma.to ;;
    *) die '--env must be mainnet, testnet, or devnet' ;;
  esac
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT

  if ((LIST_ONLY)) || [[ -n "$stamp" ]]; then
    curl -fLsS "$host/${version_prefix}index.json" -o "$scratch/index.json"
    # Only complete pairs are eligible, including when selecting a date.
    jq -e '[.runs[] | select(.components.consensus != null and .components.execution != null)]' \
      "$scratch/index.json" > "$scratch/runs.json"
    if ((LIST_ONLY)); then
      jq -r 'sort_by(.stamp)[] | .stamp' "$scratch/runs.json"
      return 0
    fi
    jq --arg stamp "$stamp" '[.[] | select(.stamp | startswith($stamp))]' \
      "$scratch/runs.json" > "$scratch/matches.json"
    [[ $(jq length "$scratch/matches.json") == 1 ]] || die 'snapshot must match exactly one complete pair; use --list and a full timestamp'
    jq --arg network "$network" --arg version "$SNAPSHOT_VERSION" '.[0] + {network: $network, version: $version}' \
      "$scratch/matches.json" > "$scratch/manifest.json"
  else
    curl -fLsS "$host/${version_prefix}latest/manifest.json" -o "$scratch/manifest.json"
  fi

  # Validate keys before using them as URLs or local paths, and require both
  # components to belong to the same network, version, and timestamp.
  jq -e --arg network "$network" --arg version "$SNAPSHOT_VERSION" --arg prefix "$version_prefix" '
    . as $m | .network == $network and (.version // "v1") == $version and
    (.stamp | test("^[0-9]{8}-[0-9]{6}$")) and
    (all(["consensus", "execution"][]; . as $c |
      $m.components[$c] as $entry |
      $entry.key == ($prefix + $c + "-" + $m.stamp + ".tar.gz") and
      ($entry.sha256 | test("^sha256:[a-fA-F0-9]{64}$")) and
      ($entry.sizeBytes | type == "number" and . > 0 and floor == .)))
  ' "$scratch/manifest.json" > /dev/null || die "invalid or incomplete R2 $SNAPSHOT_VERSION manifest"
  stamp=$(jq -r .stamp "$scratch/manifest.json")
  info "Using $network $SNAPSHOT_VERSION snapshot: $stamp"
  info "Destination: $dest"

  for component in consensus execution; do
    jq -r --arg component "$component" '.components[$component] | "\(.key)  \(.sizeBytes) bytes  \(.sha256)"' "$scratch/manifest.json"
  done
  if ((DRY_RUN)); then
    jq -r --arg host "$host" '.components[] | $host + "/" + .key' "$scratch/manifest.json"
    return 0
  fi

  mkdir -p "$dest"
  dest=$(cd "$dest" && pwd)
  # Compose chooses archives independently by name; reject a directory containing
  # another timestamp so an interrupted run cannot leave it with a mixed pair.
  for archive in "$dest"/consensus-*.tar.gz "$dest"/execution-*.tar.gz; do
    [[ -e "$archive" ]] || continue
    case "${archive##*/}" in
      "consensus-$stamp.tar.gz"|"execution-$stamp.tar.gz") ;;
      *) die "move other snapshot archives out of $dest before downloading $stamp" ;;
    esac
  done

  for component in consensus execution; do
    key=$(jq -r --arg c "$component" '.components[$c].key' "$scratch/manifest.json")
    digest=$(jq -r --arg c "$component" '.components[$c].sha256 | sub("^sha256:"; "")' "$scratch/manifest.json")
    size=$(jq -r --arg c "$component" '.components[$c].sizeBytes' "$scratch/manifest.json")
    download_object "$host/$key" "$size" "$host/$version_prefix" "$digest"
  done

  # Publish only after both components have passed validation.
  for component in consensus execution; do
    file="$component-$stamp.tar.gz"
    if [[ ! -f "$dest/$file" ]]; then mv "$dest/$file.part" "$dest/$file"; fi
  done
  cp "$scratch/manifest.json" "$dest/manifest-$SNAPSHOT_VERSION.json"
  info "Verified snapshot $stamp is ready in $dest"
)

bucket_for_env() {
  case "$1" in
  mainnet) printf '%s\n' "${PLASMA_MAINNET_BACKUPS_BUCKET:-plasma-mainnet-db-backups}" ;;
  testnet) printf '%s\n' "${PLASMA_TESTNET_BACKUPS_BUCKET:-plasma-testnet-db-backups}" ;;
  devnet) printf '%s\n' "${PLASMA_DEVNET_BACKUPS_BUCKET:-plasma-devnet-db-backups}" ;;
  *) die "unknown env '$1'; expected mainnet, testnet, or devnet" ;;
  esac
}

SOURCE="r2"
SNAPSHOT_VERSION="v2"
S3_OPTIONS=()
ENVIRONMENT=""
BUCKET=""
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
PREFIX=""
FOLDER=""
SNAPSHOT=""
DESTDIR=""
CHUNK_SIZE="$(parse_size 5G)"
DRY_RUN=0
KEEP_PARTS=0
GZIP_TEST=1
LATEST=0
LIST_ONLY=0
USE_S5CMD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --source | --version | --env | --dest | --snapshot | --bucket | --profile | --region | --prefix | --folder | --chunk-size)
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value"
    ;;
  esac
  case "$1" in
  --bucket | --profile | --region | --prefix | --folder | --chunk-size | --keep-parts | --use-s5cmd)
    S3_OPTIONS+=("$1")
    ;;
  esac
  case "$1" in
  --source)
    SOURCE="$2"
    shift 2
    ;;
  --version)
    SNAPSHOT_VERSION="$2"
    shift 2
    ;;
  --env)
    ENVIRONMENT="${2:-}"
    shift 2
    ;;
  --bucket)
    BUCKET="${2:-}"
    shift 2
    ;;
  --profile)
    PROFILE="${2:-}"
    shift 2
    ;;
  --region)
    REGION="${2:-}"
    shift 2
    ;;
  --prefix)
    PREFIX="$(ensure_trailing_slash "${2:-}")"
    shift 2
    ;;
  --folder)
    FOLDER="${2:-}"
    shift 2
    ;;
  --snapshot)
    SNAPSHOT="${2:-}"
    shift 2
    ;;
  --dest)
    DESTDIR="${2:-}"
    shift 2
    ;;
  --chunk-size)
    CHUNK_SIZE="$(parse_size "${2:-}")"
    shift 2
    ;;
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  --keep-parts)
    KEEP_PARTS=1
    shift
    ;;
  --no-gzip-test)
    GZIP_TEST=0
    shift
    ;;
  --latest)
    LATEST=1
    shift
    ;;
  --list)
    LIST_ONLY=1
    shift
    ;;
  --use-s5cmd)
    USE_S5CMD=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument '$1'"
    ;;
  esac
done

[[ -n "$ENVIRONMENT" ]] || die "--env is required"
[[ "$ENVIRONMENT" =~ ^(mainnet|testnet|devnet)$ ]] || die "--env must be mainnet, testnet, or devnet"

[[ "$SOURCE" == r2 || "$SOURCE" == s3 ]] || die '--source must be r2 or s3'
[[ "$SNAPSHOT_VERSION" == v1 || "$SNAPSHOT_VERSION" == v2 ]] || die '--version must be v1 or v2'

if [[ -n "$SNAPSHOT" ]]; then
  # Accept 2026-06-06 as well as 20260606 for the date part.
  if [[ "$SNAPSHOT" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    SNAPSHOT="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  [[ "$SNAPSHOT" =~ ^[0-9]{8}(-[0-9]{6})?$ ]] || die "--snapshot must be YYYYMMDD-HHMMSS, YYYYMMDD or YYYY-MM-DD, got '$SNAPSHOT'"
fi
[[ -n "$DESTDIR" ]] || DESTDIR="./config/$ENVIRONMENT/snapshots"
((CHUNK_SIZE > 0)) || die "--chunk-size must be greater than zero"

if [[ "$SOURCE" == r2 ]]; then
  ((${#S3_OPTIONS[@]} == 0)) || die "${S3_OPTIONS[*]} require --source s3"
  [[ -z "$SNAPSHOT" || "$LATEST" == 0 ]] || die '--latest and --snapshot are mutually exclusive'
  for tool in curl jq sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
  if ((GZIP_TEST && !LIST_ONLY && !DRY_RUN)); then
    command -v gzip >/dev/null 2>&1 || die 'gzip is required'
  fi
fi

if [[ -z "$BUCKET" ]]; then
  BUCKET="$(bucket_for_env "$ENVIRONMENT")"
fi

if [[ -n "$FOLDER" && "$FOLDER" == s3://* ]]; then
  normalized="${FOLDER#s3://}"
  [[ "$normalized" == */* ]] || die "--folder S3 URI must include a bucket and prefix"
  BUCKET="${normalized%%/*}"
  FOLDER="${normalized#*/}"
  PREFIX=""
fi

[[ -n "$BUCKET" ]] || die "no default bucket for $ENVIRONMENT; pass --bucket or set PLASMA_${ENVIRONMENT^^}_BACKUPS_BUCKET"


AWS_GLOBAL_ARGS=()
if [[ -n "$PROFILE" ]]; then
  AWS_GLOBAL_ARGS+=(--profile "$PROFILE")
fi
if [[ -n "$REGION" ]]; then
  AWS_GLOBAL_ARGS+=(--region "$REGION")
fi

AWS_SSO_ARGS=()
if [[ -n "$PROFILE" ]]; then
  AWS_SSO_ARGS+=(--profile "$PROFILE")
fi

aws_s3api() {
  aws "${AWS_GLOBAL_ARGS[@]}" s3api "$@"
}

ensure_login() {
  if aws "${AWS_GLOBAL_ARGS[@]}" sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi

  info "AWS credentials are unavailable or expired; running aws sso login."
  aws "${AWS_SSO_ARGS[@]}" sso login >/dev/null
  aws "${AWS_GLOBAL_ARGS[@]}" sts get-caller-identity >/dev/null
}

list_keys() {
  local prefix="$1"
  ensure_login
  aws_s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$prefix" \
    --request-payer requester \
    --query 'Contents[].Key' \
    --output text |
    tr '\t' '\n' |
    sed '/^None$/d;/^$/d'
}

# Snapshot object names: <component>-backup-<YYYYMMDD-HHMMSS>.tar.gz. Capture 1 is the
# parent prefix (with trailing slash, may be empty), capture 2 the timestamp stamp.
SNAPSHOT_KEY_RE='^(.*/)?[A-Za-z0-9_.-]+-backup-([0-9]{8}-[0-9]{6})\.tar\.gz$'

# Discovered snapshots are lines of "<stamp>\t<parent prefix>". The stamp is
# YYYYMMDD-HHMMSS, so a plain byte-wise sort is chronological; the legacy
# MM-DD-YY folder is never consulted, which is why it does not matter whether
# objects sit flat under the prefix or inside such a folder.
discover_snapshots() {
  local prefix="$1"
  declare -A seen=()
  local key stamp parent version

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    [[ "$key" =~ $SNAPSHOT_KEY_RE ]] || continue
    stamp="${BASH_REMATCH[2]}"
    parent="${BASH_REMATCH[1]}"
    version=v1
    if [[ "$parent" =~ (^|/)(v[0-9]+)(/|$) ]]; then
      version="${BASH_REMATCH[2]}"
    fi
    [[ "$version" == "$SNAPSHOT_VERSION" ]] || continue
    seen["$stamp"$'\t'"$parent"]=1
  done < <(list_keys "$prefix")

  for key in "${!seen[@]}"; do
    printf '%s\n' "$key"
  done | LC_ALL=C sort
}

snapshot_stamp() {
  printf '%s\n' "${1%%$'\t'*}"
}

snapshot_parent() {
  printf '%s\n' "${1#*$'\t'}"
}

describe_snapshot() {
  printf '%s  s3://%s/%s\n' "$(snapshot_stamp "$1")" "$BUCKET" "$(snapshot_parent "$1")"
}

select_snapshot() {
  local -a snapshots=("$@")
  local choice i

  [[ "${#snapshots[@]}" -gt 0 ]] || die "no $SNAPSHOT_VERSION snapshots (*-backup-YYYYMMDD-HHMMSS.tar.gz) found in s3://$BUCKET/$PREFIX"

  if [[ "${#snapshots[@]}" -eq 1 ]]; then
    printf '%s\n' "${snapshots[0]}"
    return 0
  fi

  if ((LATEST)); then
    local newest="${snapshots[$((${#snapshots[@]} - 1))]}"
    local newest_stamp
    newest_stamp="$(snapshot_stamp "$newest")"
    local -a ties=()
    for i in "${!snapshots[@]}"; do
      if [[ "$(snapshot_stamp "${snapshots[$i]}")" == "$newest_stamp" ]]; then
        ties+=("${snapshots[$i]}")
      fi
    done
    if [[ "${#ties[@]}" -gt 1 ]]; then
      info "Several snapshot sources share the newest timestamp $newest_stamp:"
      for i in "${!ties[@]}"; do
        info "  $(describe_snapshot "${ties[$i]}")"
      done
      die "pass --prefix to choose a snapshot source"
    fi
    printf '%s\n' "$newest"
    return 0
  fi

  if [[ -n "$FOLDER" || -n "$SNAPSHOT" ]]; then
    die "multiple snapshots matched; narrow with --prefix, a full --snapshot timestamp, or --latest"
  fi

  [[ -t 0 ]] || die "multiple snapshots found; pass --snapshot, --prefix, or --latest"

  info "Available snapshots in s3://$BUCKET/${PREFIX}:"
  for i in "${!snapshots[@]}"; do
    printf '%3d) %s\n' "$((i + 1))" "$(describe_snapshot "${snapshots[$i]}")" >&2
  done

  while true; do
    read -r -p "Select snapshot [1-${#snapshots[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#snapshots[@]})); then
      printf '%s\n' "${snapshots[$((choice - 1))]}"
      return 0
    fi
    info "Enter a number from 1 to ${#snapshots[@]}."
  done
}

resolve_snapshot() {
  local folder parent entry
  local -a snapshots matches

  mapfile -t snapshots < <(discover_snapshots "$PREFIX")
  matches=("${snapshots[@]}")

  if [[ -n "$SNAPSHOT" ]]; then
    local -a by_stamp=()
    for entry in "${matches[@]}"; do
      if [[ "$(snapshot_stamp "$entry")" == "$SNAPSHOT"* ]]; then
        by_stamp+=("$entry")
      fi
    done
    [[ "${#by_stamp[@]}" -gt 0 ]] || die "no snapshot with timestamp '$SNAPSHOT' in s3://$BUCKET/$PREFIX"
    matches=("${by_stamp[@]}")
  fi

  if [[ -n "$FOLDER" ]]; then
    folder="$(trim_slashes "$FOLDER")"
    local -a by_folder=()
    for entry in "${matches[@]}"; do
      parent="$(snapshot_parent "$entry")"
      if [[ "$folder" == */* ]]; then
        # Full prefix: exact match on the parent folder.
        [[ "$parent" == "$folder/" ]] && by_folder+=("$entry")
      else
        # Bare folder name: match the last path segment (legacy MM-DD-YY folders).
        [[ "$parent" == "$folder/" || "$parent" == */"$folder/" ]] && by_folder+=("$entry")
      fi
    done
    [[ "${#by_folder[@]}" -gt 0 ]] || die "snapshot folder '$FOLDER' was not found in s3://$BUCKET/$PREFIX"
    matches=("${by_folder[@]}")
  fi

  select_snapshot "${matches[@]}"
}

list_objects_for_prefix() {
  local snapshot_prefix="$1"
  ensure_login
  aws_s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$snapshot_prefix" \
    --request-payer requester \
    --query 'Contents[?Size>`0`].[Key,Size]' \
    --output text |
    sed '/^None$/d;/^$/d'
}

verify_archive() {
  local file="$1"
  local expected_size="${2:-}"
  local digest="${3:-}"
  local actual_size

  if [[ -n "$expected_size" ]]; then
    actual_size="$(stat_size "$file")"
    [[ "$actual_size" -eq "$expected_size" ]] ||
      die "$file has $actual_size bytes; expected $expected_size"
  fi
  if [[ -n "$digest" ]]; then
    printf '%s  %s\n' "$digest" "${file##*/}" |
      (cd "$(dirname "$file")" && sha256sum -c -)
  fi
  if ((GZIP_TEST)); then
    info "gzip test: $file"
    gzip -t "$file"
  fi
}

download_object() {
  local key="$1"
  local listed_size="$2"
  local snapshot_prefix="$3"
  local digest="${4:-}"
  local rel dest dest_dir parts_dir size etag parts i start end expected part tmp
  local assembling actual_size url

  rel="${key#"$snapshot_prefix"}"
  [[ -n "$rel" && "$rel" != "$key" ]] || rel="${key##*/}"
  dest="$DESTDIR/$rel"
  dest_dir="$(dirname "$dest")"
  parts_dir="$DESTDIR/.parts/$rel.parts"

  if [[ "$SOURCE" == r2 ]]; then
    size="$listed_size"
    url="$key"
  else
    url="s3://$BUCKET/$key"
    ensure_login
    read -r size etag < <(
      aws_s3api head-object \
        --bucket "$BUCKET" \
        --key "$key" \
        --request-payer requester \
        --query '[ContentLength,ETag]' \
        --output text
    )
  fi

  if [[ "$size" != "$listed_size" ]]; then
    info "Object size changed since listing: $key ($listed_size -> $size)"
  fi

  if [[ -f "$dest" ]]; then
    verify_archive "$dest" "$size" "$digest"
    info "skip complete file: $dest ($(human_bytes "$size"))"
    return 0
  fi

  info "download: $url -> $dest ($(human_bytes "$size"))"
  if ((DRY_RUN)); then
    return 0
  fi

  mkdir -p "$dest_dir"
  if [[ "$SOURCE" == r2 ]]; then
    # Keep .part files resumable and hidden from Compose until the pair is verified.
    actual_size="$(stat_size "$dest.part")"
    if ((actual_size > size)); then
      die "$dest.part has $actual_size bytes; expected $size. Move it aside before retrying."
    fi
    if ((actual_size < size)); then
      curl -fL --retry 3 -C - "$url" -o "$dest.part"
    fi
    (
      trap 'rm -f "$dest.part"' EXIT
      verify_archive "$dest.part" "$size" "$digest"
      trap - EXIT
    )
    return 0
  fi

  parts=$(((size + CHUNK_SIZE - 1) / CHUNK_SIZE))
  mkdir -p "$parts_dir"
  for ((i = 0; i < parts; i++)); do
    start=$((i * CHUNK_SIZE))
    end=$((start + CHUNK_SIZE - 1))
    if ((end >= size)); then
      end=$((size - 1))
    fi
    expected=$((end - start + 1))
    part="$(printf '%s/part-%05d' "$parts_dir" "$i")"
    tmp="$part.tmp"

    if [[ -f "$part" && "$(stat_size "$part")" -eq "$expected" ]]; then
      info "  skip part $((i + 1))/$parts"
      continue
    fi

    rm -f "$tmp"
    while true; do
      ensure_login
      if aws_s3api get-object \
        --bucket "$BUCKET" \
        --key "$key" \
        --request-payer requester \
        --if-match "$etag" \
        --range "bytes=$start-$end" \
        "$tmp" >/dev/null && [[ "$(stat_size "$tmp")" -eq "$expected" ]]; then
        mv "$tmp" "$part"
        info "  wrote part $((i + 1))/$parts"
        break
      fi

      rm -f "$tmp"
      info "  retrying part $((i + 1))/$parts after failed range request"
      sleep 5
    done
  done

  assembling="$dest.assembling"
  rm -f "$assembling"
  for ((i = 0; i < parts; i++)); do
    part="$(printf '%s/part-%05d' "$parts_dir" "$i")"
    [[ -f "$part" ]] || die "missing part while assembling: $part"
    cat "$part" >>"$assembling"
    if ((!KEEP_PARTS)); then
      rm -f "$part"
    fi
  done

  verify_archive "$assembling" "$size" "$digest"
  mv "$assembling" "$dest"

  if ((!KEEP_PARTS)); then
    rmdir "$parts_dir" 2>/dev/null || true
  fi

  info "done: $dest"
}

download_with_s5cmd() {
  local snapshot_prefix="$1"
  local stamp="$2"
  local src="s3://$BUCKET/${snapshot_prefix}*-backup-${stamp}.tar.gz"

  ensure_login
  mkdir -p "$DESTDIR"

  info "Downloading with s5cmd: $src -> $DESTDIR/"
  if ((DRY_RUN)); then
    info "[dry-run] s5cmd --request-payer requester cp --concurrency 250 '$src' '$DESTDIR/'"
    return 0
  fi

  # s5cmd has its own AWS credential resolution and may not understand SSO profiles. Bridge by
  # exporting the AWS CLI's already-resolved temporary credentials into the environment. Fall back
  # to s5cmd's own resolution (with --profile) if export fails.
  local cred_env=""
  local -a s5_global=(--request-payer requester)
  if cred_env="$(aws "${AWS_GLOBAL_ARGS[@]}" configure export-credentials --format env 2>/dev/null)" && [[ -n "$cred_env" ]]; then
    :
  else
    cred_env=""
    [[ -n "$PROFILE" ]] && s5_global+=(--profile "$PROFILE")
  fi

  (
    if [[ -n "$cred_env" ]]; then
      unset AWS_PROFILE AWS_DEFAULT_PROFILE
      eval "$cred_env"
    fi
    export AWS_REGION="$REGION"
    s5cmd "${s5_global[@]}" cp --concurrency 250 "$src" "$DESTDIR/"
  )

  if ((GZIP_TEST)); then
    local f
    for f in "$DESTDIR"/*.tar.gz; do
      [[ -e "$f" ]] || continue
      verify_archive "$f"
    done
  fi

  info "done: $DESTDIR"
}

if [[ "$SOURCE" == r2 ]]; then
  download_r2
  exit 0
fi

command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v gzip >/dev/null 2>&1 || die "gzip is required"
if ((USE_S5CMD)); then
  command -v s5cmd >/dev/null 2>&1 ||
    die "s5cmd not found on PATH. Install it: https://github.com/peak/s5cmd#installation"
fi

if ((LIST_ONLY)); then
  while IFS= read -r entry; do
    describe_snapshot "$entry"
  done < <(discover_snapshots "$PREFIX")
  exit 0
fi

SELECTED="$(resolve_snapshot)"
SNAPSHOT_STAMP="$(snapshot_stamp "$SELECTED")"
SNAPSHOT_PREFIX="$(snapshot_parent "$SELECTED")"
info "Using $SNAPSHOT_VERSION snapshot: s3://$BUCKET/${SNAPSHOT_PREFIX}*-backup-${SNAPSHOT_STAMP}.tar.gz"
info "Destination: $DESTDIR"

if ((USE_S5CMD)); then
  download_with_s5cmd "$SNAPSHOT_PREFIX" "$SNAPSHOT_STAMP"
  exit 0
fi

info "Chunk size: $(human_bytes "$CHUNK_SIZE")"

# Only the objects of the selected snapshot: other timestamps share the prefix in
# the flat layout.
mapfile -t OBJECTS < <(list_objects_for_prefix "$SNAPSHOT_PREFIX" |
  grep -E $'^[^\t]*-backup-'"$SNAPSHOT_STAMP"$'\.tar\.gz\t' || true)
[[ "${#OBJECTS[@]}" -gt 0 ]] || die "no objects found for snapshot $SNAPSHOT_STAMP under s3://$BUCKET/$SNAPSHOT_PREFIX"

for line in "${OBJECTS[@]}"; do
  key="${line%$'\t'*}"
  size="${line##*$'\t'}"
  download_object "$key" "$size" "$SNAPSHOT_PREFIX"
done
