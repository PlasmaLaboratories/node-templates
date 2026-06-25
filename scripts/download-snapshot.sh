#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/download-snapshot.sh --env mainnet [options]
  scripts/download-snapshot.sh --env testnet [options]
  scripts/download-snapshot.sh --env devnet [options]

Downloads Plasma database snapshots from requester-pays S3 buckets using
restartable byte-range chunks.

Options:
  --env ENV              Network environment: mainnet, testnet, or devnet.
  --bucket BUCKET        Override the environment's default S3 bucket.
  --profile PROFILE      AWS CLI profile to use. Defaults to AWS_PROFILE/default resolution.
  --region REGION        AWS region. Defaults to AWS_REGION, AWS_DEFAULT_REGION, or us-east-2.
  --prefix PREFIX        Limit discovery to a bucket prefix, e.g. mainnet/observer-0/.
  --folder FOLDER        Snapshot folder/date or full prefix, e.g. 06-06-26 or mainnet/observer-0/06-06-26.
  --latest              Select the newest discovered snapshot folder without prompting.
  --dest DIR             Destination directory. Defaults to ./config/ENV/snapshots.
  --chunk-size SIZE      Chunk size for ranged downloads. Defaults to 5GiB. Examples: 1G, 512M.
  --dry-run             Show what would be downloaded without downloading.
  --keep-parts          Keep part files after assembling final files.
  --no-gzip-test        Skip gzip validation for files ending in .gz.
  --list                List discovered snapshot folders and exit.
  -h, --help            Show this help.

Environment bucket defaults:
  mainnet: PLASMA_MAINNET_BACKUPS_BUCKET or plasma-mainnet-db-backups
  testnet: PLASMA_TESTNET_BACKUPS_BUCKET or plasma-testnet-db-backups
  devnet:  PLASMA_DEVNET_BACKUPS_BUCKET or plasma-devnet-db-backups

Examples:
  scripts/download-snapshot.sh --env mainnet --prefix mainnet/observer-0/ --latest
  scripts/download-snapshot.sh --env mainnet --prefix mainnet/observer-0/ --latest --profile plasma-snapshots
  scripts/download-snapshot.sh --env mainnet --folder 06-06-26 --prefix mainnet/observer-0/
  scripts/download-snapshot.sh --env testnet --prefix testnet/observer-0/ --latest
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
    K|KB|KIB) multiplier=1024 ;;
    M|MB|MIB) multiplier=$((1024 * 1024)) ;;
    G|GB|GIB) multiplier=$((1024 * 1024 * 1024)) ;;
    T|TB|TIB) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
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

bucket_for_env() {
  case "$1" in
    mainnet) printf '%s\n' "${PLASMA_MAINNET_BACKUPS_BUCKET:-plasma-mainnet-db-backups}" ;;
    testnet) printf '%s\n' "${PLASMA_TESTNET_BACKUPS_BUCKET:-plasma-testnet-db-backups}" ;;
    devnet) printf '%s\n' "${PLASMA_DEVNET_BACKUPS_BUCKET:-plasma-devnet-db-backups}" ;;
    *) die "unknown env '$1'; expected mainnet, testnet, or devnet" ;;
  esac
}

ENVIRONMENT=""
BUCKET=""
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
PREFIX=""
FOLDER=""
DESTDIR=""
CHUNK_SIZE="$(parse_size 5G)"
DRY_RUN=0
KEEP_PARTS=0
GZIP_TEST=1
LATEST=0
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    -h|--help)
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
[[ -n "$DESTDIR" ]] || DESTDIR="./config/$ENVIRONMENT/snapshots"
(( CHUNK_SIZE > 0 )) || die "--chunk-size must be greater than zero"

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

discover_snapshot_prefixes() {
  local prefix="$1"
  declare -A seen=()
  local key segment current

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    IFS='/' read -r -a segments <<< "$key"
    current=""
    for segment in "${segments[@]}"; do
      [[ -n "$segment" ]] || continue
      current+="$segment/"
      if [[ "$segment" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        seen["$current"]=1
        break
      fi
    done
  done < <(list_keys "$prefix")

  for key in "${!seen[@]}"; do
    printf '%s\n' "$key"
  done | sort -V
}

select_snapshot_prefix() {
  local -a prefixes=("$@")
  local choice

  [[ "${#prefixes[@]}" -gt 0 ]] || die "no date-style snapshot folders found in s3://$BUCKET/$PREFIX"

  if [[ "${#prefixes[@]}" -eq 1 ]]; then
    printf '%s\n' "${prefixes[0]}"
    return 0
  fi

  if (( LATEST )); then
    printf '%s\n' "${prefixes[$((${#prefixes[@]} - 1))]}"
    return 0
  fi

  if [[ -n "$FOLDER" ]]; then
    die "multiple folders matched '$FOLDER'; pass --prefix or a full --folder path"
  fi

  [[ -t 0 ]] || die "multiple snapshot folders found; pass --folder, --prefix, or --latest"

  info "Available snapshot folders in s3://$BUCKET/${PREFIX}:"
  local i
  for i in "${!prefixes[@]}"; do
    printf '%3d) %s\n' "$((i + 1))" "${prefixes[$i]}" >&2
  done

  while true; do
    read -r -p "Select snapshot [1-${#prefixes[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#prefixes[@]} )); then
      printf '%s\n' "${prefixes[$((choice - 1))]}"
      return 0
    fi
    info "Enter a number from 1 to ${#prefixes[@]}."
  done
}

resolve_snapshot_prefix() {
  local folder normalized match basename
  local -a prefixes matches

  mapfile -t prefixes < <(discover_snapshot_prefixes "$PREFIX")

  if [[ -z "$FOLDER" ]]; then
    select_snapshot_prefix "${prefixes[@]}"
    return 0
  fi

  folder="$(trim_slashes "$FOLDER")"
  matches=()

  if [[ "$folder" == */* ]]; then
    match="$(ensure_trailing_slash "$folder")"
    for normalized in "${prefixes[@]}"; do
      if [[ "$normalized" == "$match" ]]; then
        matches+=("$normalized")
      fi
    done
    if [[ "${#matches[@]}" -eq 0 ]]; then
      matches+=("$match")
    fi
  else
    for normalized in "${prefixes[@]}"; do
      basename="${normalized%/}"
      basename="${basename##*/}"
      if [[ "$basename" == "$folder" ]]; then
        matches+=("$normalized")
      fi
    done
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "snapshot folder '$FOLDER' was not found in s3://$BUCKET/$PREFIX"
  fi

  select_snapshot_prefix "${matches[@]}"
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

download_object() {
  local key="$1"
  local listed_size="$2"
  local snapshot_prefix="$3"
  local rel dest dest_dir parts_dir size etag parts i start end expected part tmp
  local assembling actual_size

  rel="${key#"$snapshot_prefix"}"
  [[ -n "$rel" && "$rel" != "$key" ]] || rel="${key##*/}"
  dest="$DESTDIR/$rel"
  dest_dir="$(dirname "$dest")"
  parts_dir="$DESTDIR/.parts/$rel.parts"

  ensure_login
  read -r size etag < <(
    aws_s3api head-object \
      --bucket "$BUCKET" \
      --key "$key" \
      --request-payer requester \
      --query '[ContentLength,ETag]' \
      --output text
  )

  if [[ "$size" != "$listed_size" ]]; then
    info "Object size changed since listing: $key ($listed_size -> $size)"
  fi

  if [[ -f "$dest" ]]; then
    actual_size="$(stat_size "$dest")"
    if [[ "$actual_size" -eq "$size" ]]; then
      info "skip complete file: $dest ($(human_bytes "$size"))"
      return 0
    fi
    die "$dest already exists but is $actual_size bytes; expected $size. Move it aside before retrying."
  fi

  parts=$(( (size + CHUNK_SIZE - 1) / CHUNK_SIZE ))
  info "download: s3://$BUCKET/$key -> $dest ($(human_bytes "$size"), $parts parts)"

  if (( DRY_RUN )); then
    return 0
  fi

  mkdir -p "$dest_dir" "$parts_dir"

  for ((i = 0; i < parts; i++)); do
    start=$((i * CHUNK_SIZE))
    end=$((start + CHUNK_SIZE - 1))
    if (( end >= size )); then
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
    cat "$part" >> "$assembling"
    if (( ! KEEP_PARTS )); then
      rm -f "$part"
    fi
  done

  actual_size="$(stat_size "$assembling")"
  [[ "$actual_size" -eq "$size" ]] || die "assembled file has $actual_size bytes; expected $size"

  mv "$assembling" "$dest"

  if (( GZIP_TEST )) && [[ "$dest" == *.gz ]]; then
    info "gzip test: $dest"
    gzip -t "$dest"
  fi

  if (( ! KEEP_PARTS )); then
    rmdir "$parts_dir" 2>/dev/null || true
  fi

  info "done: $dest"
}

command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v gzip >/dev/null 2>&1 || die "gzip is required"

if (( LIST_ONLY )); then
  discover_snapshot_prefixes "$PREFIX"
  exit 0
fi

SNAPSHOT_PREFIX="$(resolve_snapshot_prefix)"
info "Using snapshot prefix: s3://$BUCKET/$SNAPSHOT_PREFIX"
info "Destination: $DESTDIR"
info "Chunk size: $(human_bytes "$CHUNK_SIZE")"

mapfile -t OBJECTS < <(list_objects_for_prefix "$SNAPSHOT_PREFIX")
[[ "${#OBJECTS[@]}" -gt 0 ]] || die "no objects found under s3://$BUCKET/$SNAPSHOT_PREFIX"

for line in "${OBJECTS[@]}"; do
  key="${line%$'\t'*}"
  size="${line##*$'\t'}"
  download_object "$key" "$size" "$SNAPSHOT_PREFIX"
done
