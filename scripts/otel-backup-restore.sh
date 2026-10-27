#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  START_DATE=YYYY-MM-DD END_DATE=YYYY-MM-DD BACKUP_DIR=/path/to/backup \
    ./scripts/otel-backup-restore.sh backup

  START_DATE=YYYY-MM-DD END_DATE=YYYY-MM-DD BACKUP_DIR=/path/to/backup \
    ./scripts/otel-backup-restore.sh restore

Required environment variables:
  START_DATE        Inclusive UTC date.
  END_DATE          Inclusive UTC date.
  BACKUP_DIR        Local directory for Parquet backup files.

Optional environment variables:
  SOURCE_CONTEXT    kubectl context of the source cluster.
  TARGET_CONTEXT    kubectl context of the target cluster.
  SOURCE_NAMESPACE  Source namespace. Default: clickhouse.
  TARGET_NAMESPACE  Target namespace. Default: clickhouse.
  SOURCE_CHI        Source ClickHouseInstallation name. Default: clickhouse.
  TARGET_CHI        Target ClickHouseInstallation name. Default: clickhouse.
  SOURCE_CLUSTER    Source CHI cluster name. Default: main.
  TARGET_CLUSTER    Target CHI cluster name. Default: main.
  SOURCE_CONTAINER  Source ClickHouse container name. Default: clickhouse.
  TARGET_CONTAINER  Target ClickHouse container name. Default: clickhouse.
  RESTORE_STATE_DIR Completed-file marker directory. Default: BACKUP_DIR/.restore-state.
  FORCE_RESTORE     Set to yes to import files marked as completed.
EOF
  exit 2
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

context_args() {
  local context=$1
  if [[ -n "$context" ]]; then
    printf '%s\0%s\0' --context "$context"
  fi
}

kubectl_for() {
  local context=$1
  local -a args=()
  while IFS= read -r -d '' argument; do
    args+=("$argument")
  done < <(context_args "$context")
  kubectl "${args[@]}" "$@"
}

require_date() {
  local value=$1
  date -u -d "$value" +%F >/dev/null 2>&1 && [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

next_date() {
  date -u -d "$1 + 1 day" +%F
}

source_pods() {
  kubectl_for "$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" get pods \
    -l "clickhouse.altinity.com/chi=${SOURCE_CHI},clickhouse.altinity.com/cluster=${SOURCE_CLUSTER},clickhouse.altinity.com/replica=0" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

target_pod() {
  kubectl_for "$TARGET_CONTEXT" -n "$TARGET_NAMESPACE" get pods \
    -l "clickhouse.altinity.com/chi=${TARGET_CHI},clickhouse.altinity.com/cluster=${TARGET_CLUSTER},clickhouse.altinity.com/shard=0,clickhouse.altinity.com/replica=0" \
    -o jsonpath='{.items[0].metadata.name}'
}

backup_table() {
  local table=$1
  local timestamp_column=$2
  local day=$3
  local next_day=$4
  local pod=$5
  local destination="$BACKUP_DIR/$table/$day/$pod.parquet"
  local temporary="${destination}.partial"
  local query

  mkdir -p "$(dirname "$destination")"
  query="SELECT * FROM otel.${table}_local WHERE ${timestamp_column} >= toDateTime('${day} 00:00:00', 'UTC') AND ${timestamp_column} < toDateTime('${next_day} 00:00:00', 'UTC') FORMAT Parquet"

  log "Exporting ${table} from ${pod} for ${day}"
  kubectl_for "$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" exec "$pod" -c "$SOURCE_CONTAINER" -- \
    clickhouse-client --query "$query" >"$temporary"
  mv "$temporary" "$destination"
}

restore_table() {
  local table=$1
  local day=$2
  local pod=$3
  local source_file=$4
  local marker="$RESTORE_STATE_DIR/$table/$day/$pod.done"

  if [[ "${FORCE_RESTORE:-no}" != "yes" && -f "$marker" ]]; then
    log "Skipping already restored ${source_file}"
    return
  fi

  mkdir -p "$(dirname "$marker")"
  log "Restoring ${source_file} into otel.${table}"
  kubectl_for "$TARGET_CONTEXT" -n "$TARGET_NAMESPACE" exec -i "$TARGET_POD" -c "$TARGET_CONTAINER" -- \
    clickhouse-client --query "INSERT INTO otel.${table} FORMAT Parquet" <"$source_file"
  touch "$marker"
}

ACTION=${1:-}
[[ "$ACTION" == "backup" || "$ACTION" == "restore" ]] || usage

START_DATE=${START_DATE:-}
END_DATE=${END_DATE:-}
BACKUP_DIR=${BACKUP_DIR:-}
SOURCE_CONTEXT=${SOURCE_CONTEXT:-}
TARGET_CONTEXT=${TARGET_CONTEXT:-}
SOURCE_NAMESPACE=${SOURCE_NAMESPACE:-clickhouse}
TARGET_NAMESPACE=${TARGET_NAMESPACE:-clickhouse}
SOURCE_CHI=${SOURCE_CHI:-clickhouse}
TARGET_CHI=${TARGET_CHI:-clickhouse}
SOURCE_CLUSTER=${SOURCE_CLUSTER:-main}
TARGET_CLUSTER=${TARGET_CLUSTER:-main}
SOURCE_CONTAINER=${SOURCE_CONTAINER:-clickhouse}
TARGET_CONTAINER=${TARGET_CONTAINER:-clickhouse}

require_date "$START_DATE" || usage
require_date "$END_DATE" || usage
[[ "$START_DATE" > "$END_DATE" ]] && usage
[[ -n "$BACKUP_DIR" ]] || usage

umask 077
mkdir -p "$BACKUP_DIR"
RESTORE_STATE_DIR=${RESTORE_STATE_DIR:-"$BACKUP_DIR/.restore-state"}

declare -A TIME_COLUMNS=(
  [otel_logs]=Timestamp
  [otel_traces]=Timestamp
  [otel_metrics_gauge]=TimeUnix
  [otel_metrics_sum]=TimeUnix
  [otel_metrics_histogram]=TimeUnix
  [otel_metrics_exponential_histogram]=TimeUnix
  [otel_metrics_summary]=TimeUnix
)
TABLES=(
  otel_logs
  otel_traces
  otel_metrics_gauge
  otel_metrics_sum
  otel_metrics_histogram
  otel_metrics_exponential_histogram
  otel_metrics_summary
)

if [[ "$ACTION" == "backup" ]]; then
  mapfile -t SOURCE_PODS < <(source_pods)
  ((${#SOURCE_PODS[@]} > 0)) || {
    log "No source replica-0 ClickHouse pods found"
    exit 1
  }

  day=$START_DATE
  while [[ "$day" <="$END_DATE" ]]; do
    tomorrow=$(next_date "$day")
    for table in "${TABLES[@]}"; do
      for pod in "${SOURCE_PODS[@]}"; do
        backup_table "$table" "${TIME_COLUMNS[$table]}" "$day" "$tomorrow" "$pod"
      done
    done
    day=$tomorrow
  done
else
  TARGET_POD=$(target_pod)
  [[ -n "$TARGET_POD" ]] || {
    log "No target shard-0 replica-0 ClickHouse pod found"
    exit 1
  }

  day=$START_DATE
  while [[ "$day" <="$END_DATE" ]]; do
    for table in "${TABLES[@]}"; do
      table_dir="$BACKUP_DIR/$table/$day"
      [[ -d "$table_dir" ]] || {
        log "No backup directory for ${table} on ${day}; skipping"
        continue
      }
      while IFS= read -r -d '' source_file; do
        pod=$(basename "$source_file" .parquet)
        restore_table "$table" "$day" "$pod" "$source_file"
      done < <(find "$table_dir" -maxdepth 1 -type f -name '*.parquet' -print0 | sort -z)
    done
    day=$(next_date "$day")
  done
fi
