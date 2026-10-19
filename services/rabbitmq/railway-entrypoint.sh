#!/usr/bin/env bash
# RabbitMQ on Railway: prepares the node, then hands over to the image's own
# docker-entrypoint.sh (which fixes volume ownership and drops to the rabbitmq user).
#
#  - Fixed node name (default rabbit@localhost). RabbitMQ keys its database directory
#    by node name, and Railway gives the container a new hostname on every deploy.
#  - Erlang cookie from RABBITMQ_ERLANG_COOKIE, written to the cookie file.
#  - Default user and password from the service variables, via a config file
#    (RabbitMQ creates that user only when it creates a new database).
#  - Memory high watermark from the container's cgroup memory limit. RabbitMQ itself
#    reads /proc/meminfo, i.e. the host's RAM.
#  - Disk free limit sized to the volume.
#  - Erlang schedulers sized to the CPU quota (capped); epmd and the Erlang distribution
#    listen on loopback only (single node, CLI tools run inside the container).
#  - enabled_plugins kept on the volume, so `rabbitmq-plugins enable` survives redeploys.
set -euo pipefail

readonly DATA_DIR="${RABBITMQ_DATA_DIR:-/var/lib/rabbitmq}"
readonly CONF_DIR="${RAILWAY_RABBITMQ_CONF_DIR:-/etc/rabbitmq/conf.d}"
readonly RUNTIME_CONF="$CONF_DIR/90-railway-runtime.conf"
readonly IMAGE_PLUGINS_FILE=/etc/rabbitmq/enabled_plugins
readonly CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
readonly PROC_CGROUP="${PROC_CGROUP:-/proc/self/cgroup}"
readonly MEMINFO="${MEMINFO:-/proc/meminfo}"

readonly FALLBACK_MEMORY_BYTES=$((2 * 1024 * 1024 * 1024)) # assumed when no limit is visible
readonly MAX_WATERMARK_FRACTION=0.9
readonly SCHEDULER_CAP=8
readonly DISK_LIMIT_MIN=50000000   # RabbitMQ's own default (50MB)
readonly DISK_LIMIT_MAX=2000000000 # 2GB

# Sizes RabbitMQ parses (rabbit_resource_monitor_misc), without a leading zero.
readonly SIZE_RE='^[1-9][0-9]*(kB|KB|MB|GB|TB|Ki|Mi|Gi|Ti|KiB|MiB|GiB|TiB|k|K|M|G)?$'
readonly FRACTION_RE='^0?\.[0-9]+$'
# Safe in rabbitmq.conf and in an amqp:// URL without percent-encoding.
readonly CREDENTIAL_RE='^[A-Za-z0-9._-]+$'
readonly COOKIE_RE='^[A-Za-z0-9]{20,255}$'

log() { echo "[railway] $*"; }
fail() {
  echo "[railway] FATAL: $*" >&2
  exit 1
}

# --- pure helpers (no side effects) -----------------------------------------

# Smallest positive integer among the arguments; prints nothing if there is none.
min_positive() {
  local best="" value
  for value in "$@"; do
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    ((value > 0)) || continue
    if [[ -z "$best" ]] || ((value < best)); then best=$value; fi
  done
  if [[ -n "$best" ]]; then echo "$best"; fi
}

# The container's own cgroup v2 directory and its visible ancestors, one per line.
cgroup_v2_dirs() {
  [[ -r "$CGROUP_ROOT/cgroup.controllers" ]] || return 0
  local rel dir
  rel="$(awk -F: '$1 == "0" { print $3; exit }' "$PROC_CGROUP" 2>/dev/null || true)"
  case "$rel" in *..*) rel=/ ;; esac
  dir="$CGROUP_ROOT${rel%/}"
  if [[ ! -d "$dir" ]]; then dir="$CGROUP_ROOT"; fi
  while :; do
    echo "$dir"
    if [[ "$dir" == "$CGROUP_ROOT" || "$dir" != "$CGROUP_ROOT"/* ]]; then break; fi
    dir="$(dirname "$dir")"
  done
}

# Tightest memory limit (bytes) visible to the container: cgroup v2 memory.max and
# memory.high of its cgroup and ancestors, then cgroup v1. Nothing if unlimited.
cgroup_memory_limit() {
  local values=() dir file
  while IFS= read -r dir; do
    for file in memory.max memory.high; do
      if [[ -r "$dir/$file" ]]; then values+=("$(cat "$dir/$file")"); fi
    done
  done < <(cgroup_v2_dirs)
  file="$CGROUP_ROOT/memory/memory.limit_in_bytes"
  if [[ -r "$file" ]]; then values+=("$(cat "$file")"); fi
  min_positive "${values[@]+"${values[@]}"}"
}

# ceil(quota / period); nothing for "max", -1 or invalid input.
quota_to_cores() {
  [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]] || return 0
  (($1 > 0 && $2 > 0)) || return 0
  echo $((($1 + $2 - 1) / $2))
}

# Tightest CPU quota (whole cores, rounded up) visible to the container. Nothing if unlimited.
cgroup_cpu_limit() {
  local cores=() dir quota period
  while IFS= read -r dir; do
    if [[ -r "$dir/cpu.max" ]]; then
      quota="" period=""
      read -r quota period <"$dir/cpu.max" || true
      cores+=("$(quota_to_cores "$quota" "$period")")
    fi
  done < <(cgroup_v2_dirs)
  for dir in "$CGROUP_ROOT/cpu" "$CGROUP_ROOT/cpu,cpuacct" "$CGROUP_ROOT/cpuacct,cpu"; do
    if [[ -r "$dir/cpu.cfs_quota_us" && -r "$dir/cpu.cfs_period_us" ]]; then
      cores+=("$(quota_to_cores "$(cat "$dir/cpu.cfs_quota_us")" "$(cat "$dir/cpu.cfs_period_us")")")
    fi
  done
  min_positive "${cores[@]+"${cores[@]}"}"
}

host_memory_bytes() {
  local kb
  kb="$(awk '/^MemTotal:/ { print $2; exit }' "$MEMINFO" 2>/dev/null || true)"
  if [[ "$kb" =~ ^[0-9]+$ ]]; then echo $((kb * 1024)); fi
}

# 0 < value <= MAX_WATERMARK_FRACTION
is_fraction() {
  [[ "${1:-}" =~ $FRACTION_RE ]] || return 1
  awk -v f="$1" -v max="$MAX_WATERMARK_FRACTION" 'BEGIN { exit !(f > 0 && f <= max) }'
}

fraction_of() { awk -v b="$1" -v f="$2" 'BEGIN { printf "%.0f\n", b * f }'; }

mib() { echo $(($1 / 1048576)); }

# 20% of the volume, between DISK_LIMIT_MIN and DISK_LIMIT_MAX.
disk_limit_auto() {
  local limit=$(($1 / 5))
  if ((limit < DISK_LIMIT_MIN)); then limit=$DISK_LIMIT_MIN; fi
  if ((limit > DISK_LIMIT_MAX)); then limit=$DISK_LIMIT_MAX; fi
  echo "$limit"
}

# Prints "<count> <source>" for ERLANG_SCHEDULERS (validated beforehand).
scheduler_count() {
  local setting="${ERLANG_SCHEDULERS:-auto}" count source
  if [[ "$setting" != auto ]]; then
    echo "$setting ERLANG_SCHEDULERS"
    return 0
  fi
  count="$(cgroup_cpu_limit)"
  if [[ -n "$count" ]]; then
    source="cpu-quota=$count"
  else
    count="$(nproc 2>/dev/null || echo 1)"
    source="no-cpu-quota-visible,nproc=$count"
  fi
  if ((count > SCHEDULER_CAP)); then
    count=$SCHEDULER_CAP
    source="$source,capped"
  fi
  echo "$count $source"
}

# --- validation ----------------------------------------------------------------

validate_settings() {
  local user="${RABBITMQ_DEFAULT_USER:-}" pass="${RABBITMQ_DEFAULT_PASS:-}"
  local schedulers="${ERLANG_SCHEDULERS:-auto}" watermark="${MEMORY_HIGH_WATERMARK:-0.6}"
  local disk="${DISK_FREE_LIMIT:-auto}"

  [[ "$user" =~ $CREDENTIAL_RE ]] ||
    fail "RABBITMQ_DEFAULT_USER must be set and may only contain letters, digits, '.', '_' and '-'"
  [[ "$user" != guest ]] ||
    fail "RABBITMQ_DEFAULT_USER must not be 'guest' (guest may only log in from localhost)"
  { ((${#pass} >= 16)) && [[ "$pass" =~ $CREDENTIAL_RE ]]; } ||
    fail "RABBITMQ_DEFAULT_PASS must be at least 16 characters: letters, digits, '.', '_' and '-'"
  [[ "${RABBITMQ_ERLANG_COOKIE:-}" =~ $COOKIE_RE ]] ||
    fail "RABBITMQ_ERLANG_COOKIE must be 20-255 letters and digits"
  { is_fraction "$watermark" || [[ "$watermark" =~ $SIZE_RE ]]; } ||
    fail "MEMORY_HIGH_WATERMARK must be a fraction up to $MAX_WATERMARK_FRACTION (e.g. 0.6) or a size such as 1536MiB or 4GiB, got '$watermark'"
  [[ "$disk" == auto || "$disk" =~ $SIZE_RE ]] ||
    fail "DISK_FREE_LIMIT must be 'auto' or a size such as 500MB or 2GB, got '$disk'"
  [[ "$schedulers" == auto || ("$schedulers" =~ ^[1-9][0-9]*$ && "$schedulers" -le 1024) ]] ||
    fail "ERLANG_SCHEDULERS must be 'auto' or a number from 1 to 1024, got '$schedulers'"
  case "${ALLOW_TRANSIENT_QUEUES:-false}" in
  true | false) ;;
  *) fail "ALLOW_TRANSIENT_QUEUES must be true or false" ;;
  esac
}

# --- configuration steps (side effects) ------------------------------------------

configure_node_name() {
  export RABBITMQ_NODENAME="${RABBITMQ_NODENAME:-rabbit@localhost}"
  export RABBITMQ_USE_LONGNAME="${RABBITMQ_USE_LONGNAME:-false}"
  local name="${RABBITMQ_NODENAME%%@*}" host="${RABBITMQ_NODENAME#*@}"

  if [[ "$RABBITMQ_NODENAME" != *@* || -z "$name" || -z "$host" || "$host" == *@* ]]; then
    fail "RABBITMQ_NODENAME must look like name@host (default rabbit@localhost), got '$RABBITMQ_NODENAME'"
  fi
  if [[ "$RABBITMQ_USE_LONGNAME" != true && "$host" == *.* ]]; then
    fail "RABBITMQ_NODENAME host '$host' contains a dot; use a short host or set RABBITMQ_USE_LONGNAME=true"
  fi
  # The host part must resolve to this container. localhost always does; other names
  # (e.g. rabbit@rabbitmq from an older template) are mapped to the loopback address.
  if ! getent hosts "$host" >/dev/null 2>&1; then
    echo "127.0.0.1 $host" >>/etc/hosts || fail "cannot map '$host' to 127.0.0.1 in /etc/hosts"
    log "node: mapped $host to 127.0.0.1 in /etc/hosts"
  fi
  warn_other_node_dirs
}

# A changed node name silently starts an empty database; say so loudly.
warn_other_node_dirs() {
  local base="${RABBITMQ_MNESIA_BASE:-$DATA_DIR/mnesia}" others="" dir
  [[ -d "$base" && ! -d "$base/$RABBITMQ_NODENAME" ]] || return 0
  for dir in "$base"/*@*; do
    if [[ -d "$dir" && "$dir" != *-plugins-expand ]]; then others="$others ${dir##*/}"; fi
  done
  if [[ -n "$others" ]]; then
    log "WARNING: $base holds data for node(s)$others but not for $RABBITMQ_NODENAME."
    log "WARNING: RabbitMQ will start with an EMPTY database. If that data is yours, set RABBITMQ_NODENAME back to that name and redeploy."
  fi
}

write_cookie() {
  local tmp
  tmp="$(mktemp "$DATA_DIR/.erlang.cookie.XXXXXX")"
  printf '%s' "$RABBITMQ_ERLANG_COOKIE" >"$tmp"
  chmod 0400 "$tmp"
  chown rabbitmq:rabbitmq "$tmp"
  mv -f "$tmp" "$DATA_DIR/.erlang.cookie"
}

configure_plugins() {
  export RABBITMQ_ENABLED_PLUGINS_FILE="${RABBITMQ_ENABLED_PLUGINS_FILE:-$DATA_DIR/enabled_plugins}"
  local file="$RABBITMQ_ENABLED_PLUGINS_FILE" normalized list
  local re='^\[([a-z0-9_,]*)\]\.$'

  if [[ ! -s "$file" ]]; then
    if [[ -s "$IMAGE_PLUGINS_FILE" && "$IMAGE_PLUGINS_FILE" != "$file" ]]; then
      cp "$IMAGE_PLUGINS_FILE" "$file"
    else
      echo '[rabbitmq_management,rabbitmq_prometheus].' >"$file"
    fi
    log "plugins: created $file (enable more with rabbitmq-plugins; the file is on the volume)"
  fi
  normalized="$(tr -d '[:space:]' <"$file")"
  if [[ "$normalized" =~ $re ]]; then
    list="${BASH_REMATCH[1]}"
    if [[ ",$list," != *",rabbitmq_management,"* ]]; then
      list="rabbitmq_management${list:+,$list}"
      printf '[%s].\n' "$list" >"$file"
      log "plugins: re-enabled rabbitmq_management (the UI and the healthcheck need it)"
    fi
    log "plugins: ${list//,/ }"
  else
    log "WARNING: could not parse $file; leaving it unchanged"
  fi
  chown rabbitmq:rabbitmq "$file"
}

# Appends the memory settings to the runtime config file $1.
configure_memory() {
  local out="$1" setting="${MEMORY_HIGH_WATERMARK:-0.6}" host limit budget source watermark
  host="$(host_memory_bytes)"
  limit="$(cgroup_memory_limit)"
  if [[ -n "$limit" && (-z "$host" || "$limit" -lt "$host") ]]; then
    budget=$limit
    source="container memory limit"
    echo "total_memory_available_override_value = $budget" >>"$out"
  else
    budget="$(min_positive "$FALLBACK_MEMORY_BYTES" "$host")"
    source="no container memory limit visible; assumed"
  fi
  if is_fraction "$setting"; then
    watermark="$(fraction_of "$budget" "$setting")"
    log "memory: high watermark $(mib "$watermark") MiB = $setting x $(mib "$budget") MiB ($source)"
  else
    watermark="$setting"
    log "memory: high watermark $setting (MEMORY_HIGH_WATERMARK); limit seen: ${limit:-none}, host RAM: ${host:-unknown} bytes"
  fi
  echo "vm_memory_high_watermark.absolute = $watermark" >>"$out"
}

# Appends the disk free limit to the runtime config file $1.
configure_disk() {
  local out="$1" setting="${DISK_FREE_LIMIT:-auto}" volume_kb limit
  if [[ "$setting" == auto ]]; then
    volume_kb="$(df -kP "$DATA_DIR" 2>/dev/null | awk 'NR == 2 { print $2 }' || true)"
    [[ "$volume_kb" =~ ^[0-9]+$ ]] || volume_kb=0
    limit="$(disk_limit_auto $((volume_kb * 1024)))"
    log "disk: free space limit $((limit / 1000000)) MB (20% of the $((volume_kb * 1024 / 1000000)) MB volume, kept between 50 MB and 2 GB)"
  else
    limit="$setting"
    log "disk: free space limit $limit (DISK_FREE_LIMIT)"
  fi
  echo "disk_free_limit.absolute = $limit" >>"$out"
}

write_runtime_conf() {
  local tmp
  tmp="$(mktemp "$CONF_DIR/.railway-runtime.XXXXXX")"
  {
    echo "## Generated by railway-entrypoint.sh at start-up; edit the service variables instead."
    echo "## The default user is created only when RabbitMQ creates a new database."
    echo "default_user = $RABBITMQ_DEFAULT_USER"
    echo "default_pass = $RABBITMQ_DEFAULT_PASS"
  } >"$tmp"
  configure_memory "$tmp"
  configure_disk "$tmp"
  if [[ "${ALLOW_TRANSIENT_QUEUES:-false}" == true ]]; then
    echo "deprecated_features.permit.transient_nonexcl_queues = true" >>"$tmp"
    log "queues: non-durable, non-exclusive queues allowed (deprecated feature, ALLOW_TRANSIENT_QUEUES=true)"
  fi
  chmod 0600 "$tmp"
  chown rabbitmq:rabbitmq "$tmp"
  mv -f "$tmp" "$RUNTIME_CONF"
}

configure_erlang() {
  local result count source
  result="$(scheduler_count)"
  count="${result%% *}"
  source="${result#* }"
  export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"
  export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="+S $count:$count -kernel inet_dist_use_interface {127,0,0,1}${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:+ $RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS}"
  log "erlang: $count schedulers ($source); epmd and node distribution on 127.0.0.1 only"
}

main() {
  if [[ "${1:-}" != rabbitmq-server ]]; then
    exec docker-entrypoint.sh "$@"
  fi
  validate_settings
  mkdir -p "$DATA_DIR"
  configure_node_name
  write_cookie
  configure_plugins
  write_runtime_conf
  configure_erlang
  # The values now live in the config and cookie files. Keep them out of the broker's
  # environment (RabbitMQ logs the whole environment at debug level).
  unset RABBITMQ_DEFAULT_USER RABBITMQ_DEFAULT_PASS RABBITMQ_ERLANG_COOKIE RABBITMQ_URL AMQP_URL
  log "starting node $RABBITMQ_NODENAME: AMQP :5672, management :15672, Prometheus :15692"
  exec docker-entrypoint.sh "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
