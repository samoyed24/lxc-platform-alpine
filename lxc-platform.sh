#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-${BASE_DIR}/platform.yaml}"
CONFIG_DIR="${CONFIG_DIR:-${BASE_DIR}/lxc.d}"
declare -A USER_CFG

normalize_yaml_scalar() {
  local value="$1"

  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ "$value" =~ ^\".*\"$ ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\"/\"}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

parse_yaml_file() {
  local file="$1"
  local line key value upper_key

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="$(normalize_yaml_scalar "${BASH_REMATCH[2]}")"

      printf -v "$key" '%s' "$value"
      export "$key"

      upper_key="$(printf '%s' "$key" | tr 'a-z' 'A-Z')"
      if [ "$upper_key" != "$key" ]; then
        printf -v "$upper_key" '%s' "$value"
        export "$upper_key"
      fi
    fi
  done < "$file"
}

set_user_cfg() {
  local id="$1" key="$2" value="$3"
  key="$(printf '%s' "$key" | tr 'A-Z' 'a-z')"
  USER_CFG["${id}.${key}"]="$value"
}

parse_user_yaml_file() {
  local file="$1" id="$2"
  local line key value raw_value block_key block_mode list_values item legacy_prefix
  local subkey subvalue

  [ -f "$file" ] || return 0

  legacy_prefix="C_${id}_"
  block_key=""
  block_mode=""
  list_values=""

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [ -n "$block_key" ] && [[ "$line" =~ ^[[:space:]]+ ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
        block_mode="list"
        item="$(normalize_yaml_scalar "${BASH_REMATCH[1]}")"
        if [ -n "$list_values" ]; then
          list_values="${list_values} ${item}"
        else
          list_values="$item"
        fi
        continue
      fi

      if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
        block_mode="map"
        subkey="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
        subvalue="$(normalize_yaml_scalar "${BASH_REMATCH[2]}")"
        set_user_cfg "$id" "${block_key}.${subkey}" "$subvalue"
        continue
      fi
    fi

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      if [ -n "$block_key" ] && [ "$block_mode" = "list" ]; then
        set_user_cfg "$id" "$block_key" "$list_values"
      fi
      if [ -n "$block_key" ]; then
        block_key=""
        block_mode=""
        list_values=""
      fi

      key="${BASH_REMATCH[1]}"
      raw_value="$(printf '%s' "${BASH_REMATCH[2]}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      if [[ "$key" == "${legacy_prefix}"* ]]; then
        key="${key#$legacy_prefix}"
      elif [[ "$key" =~ ^C_[A-Za-z0-9_-]+_(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
      fi

      if [ -z "$raw_value" ]; then
        block_key="$key"
        block_mode=""
        list_values=""
      else
        value="$(normalize_yaml_scalar "$raw_value")"
        set_user_cfg "$id" "$key" "$value"
      fi

      continue
    fi
  done < "$file"

  if [ -n "$block_key" ] && [ "$block_mode" = "list" ]; then
    set_user_cfg "$id" "$block_key" "$list_values"
  fi
}

load_configs() {
  local file id

  [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 1; }

  parse_yaml_file "$CONFIG"

  USER_CFG=()

  if [ -d "$CONFIG_DIR" ]; then
    for file in "$CONFIG_DIR"/*.yaml; do
      [ -f "$file" ] || continue
      id="$(basename "$file" .yaml)"
      parse_user_yaml_file "$file" "$id"
    done
  fi
}

load_configs

SSHPIPER_TENANT_ROOT="${SSHPIPER_ROUTE_ROOT}/routes"
AGENT_RUNTIME_DIR="${AGENT_RUNTIME_DIR:-${RUNTIME_DIR}/agent}"
AGENT_BIN="${AGENT_BIN:-${AGENT_RUNTIME_DIR}/bin/lxc-platform-agent}"
AGENT_CONFIG="${AGENT_CONFIG:-${RUNTIME_DIR}/generated/agent.yaml}"
AGENT_STATE_FILE="${AGENT_STATE_FILE:-${RUNTIME_DIR}/state/agent/lxc-platform-agent-state.json}"
AGENT_LOG="${AGENT_LOG:-/var/log/lxc-platform-agent.log}"

mkdir -p "$RUNTIME_DIR" "$SSHPIPER_ROUTE_ROOT" "$SSHPIPER_TENANT_ROOT" "$IMAGE_DIR" "$RUNTIME_DIR/generated" "$RUNTIME_DIR/state/containers"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

cfg() {
  local id="$1" key="$2"
  key="$(printf '%s' "$key" | tr 'A-Z' 'a-z')"
  printf '%s' "${USER_CFG["${id}.${key}"]:-}"
}

json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ct_name() { cfg "$1" NAME; }
route_name() { cfg "$1" ROUTE; }

route_dir() {
  printf '%s/%s' "$SSHPIPER_TENANT_ROOT" "$(route_name "$1")"
}

container_state_file_by_id() {
  printf '%s/state/containers/%s.json' "$RUNTIME_DIR" "$(ct_name "$1")"
}

container_state_file_by_ct() {
  printf '%s/state/containers/%s.json' "$RUNTIME_DIR" "$1"
}

route_dir_by_ct() {
  local ct="$1" state_file route

  state_file="$(container_state_file_by_ct "$ct")"
  [ -f "$state_file" ] || return 1

  route="$(sed -n 's/^[[:space:]]*"route"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$state_file" | head -1)"
  [ -n "$route" ] || return 1

  printf '%s/%s' "$SSHPIPER_TENANT_ROOT" "$route"
}

container_state() {
  lxc-info -n "$1" 2>/dev/null | awk -F: '/State/ {gsub(/ /, "", $2); print $2}'
}

write_container_state() {
  local id="$1" ipv4="${2:-}" ct route ipv6 mask state ts out
  local enabled_raw enabled ssh_port ports sni disk memory cpu distro release arch backend_key_version bandwidth_up bandwidth_down

  ct="$(ct_name "$id")"
  route="$(route_name "$id")"
  out="$(container_state_file_by_id "$id")"

  mkdir -p "$(dirname "$out")"

  state="$(container_state "$ct")"
  [ -n "$state" ] || state="UNKNOWN"

  ipv6=""
  mask=""
  if [ -f "$(route_dir "$id")/ipv6_addr" ]; then
    ipv6="$(cat "$(route_dir "$id")/ipv6_addr")"
    mask="$(ipv6_mask)"
  fi

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  enabled_raw="$(cfg "$id" enabled)"
  enabled="true"
  if [ -n "$enabled_raw" ] && ! printf '%s' "$enabled_raw" | grep -Eiq '^(y|yes|1|true)$'; then
    enabled="false"
  fi

  ssh_port="$(cfg "$id" ssh_port)"
  ports="$(cfg "$id" ports)"
  sni="$(cfg "$id" sni)"
  disk="$(cfg "$id" disk)"
  memory="$(cfg "$id" memory)"
  cpu="$(cfg "$id" cpu)"
  distro="$(cfg "$id" distro)"
  release="$(cfg "$id" release)"
  arch="$(cfg "$id" arch)"
  backend_key_version="$(cfg "$id" backend_key_version)"
  bandwidth_up="$(cfg "$id" bandwidth_up)"
  bandwidth_down="$(cfg "$id" bandwidth_down)"
  [ -n "$distro" ] || distro="$DEFAULT_DISTRO"
  [ -n "$release" ] || release="$DEFAULT_RELEASE"
  [ -n "$arch" ] || arch="$DEFAULT_ARCH"

  cat > "$out" <<EOF2
{
  "id": "$(json_escape "$id")",
  "container": "$(json_escape "$ct")",
  "route": "$(json_escape "$route")",
  "enabled": ${enabled},
  "state": "$(json_escape "$state")",
  "ssh_port": "$(json_escape "$ssh_port")",
  "ports": "$(json_escape "$ports")",
  "sni": "$(json_escape "$sni")",
  "disk": "$(json_escape "$disk")",
  "memory": "$(json_escape "$memory")",
  "cpu": "$(json_escape "$cpu")",
  "distro": "$(json_escape "$distro")",
  "release": "$(json_escape "$release")",
  "arch": "$(json_escape "$arch")",
  "backend_key_version": "$(json_escape "$backend_key_version")",
  "bandwidth_up": "$(json_escape "$bandwidth_up")",
  "bandwidth_down": "$(json_escape "$bandwidth_down")",
  "ipv4": "$(json_escape "$ipv4")",
  "ipv6": "$(json_escape "$ipv6")",
  "ipv6_mask": "$(json_escape "$mask")",
  "updated_at": "$(json_escape "$ts")"
}
EOF2
}

ensure_route_dir() {
  local id="$1" rd
  rd="$(route_dir "$id")"

  mkdir -p "$rd" "$rd/authorized_keys.d"
  chmod 700 "$rd"

  if [ ! -f "$rd/id_rsa" ] || [ ! -f "$rd/id_rsa.pub" ]; then
    rm -f "$rd/id_rsa" "$rd/id_rsa.pub"
    ssh-keygen -t rsa -b 3072 -N "" -f "$rd/id_rsa" >/dev/null
  fi

  chmod 600 "$rd/id_rsa" "$rd/id_rsa.pub"
}

rotate_backend_key_if_needed() {
  local id="$1" rd desired current marker
  rd="$(route_dir "$id")"
  desired="$(cfg "$id" backend_key_version)"
  marker="$rd/backend_key_version"

  [ -n "$desired" ] || return 0

  current=""
  if [ -f "$marker" ]; then
    current="$(cat "$marker")"
  fi

  if [ "$desired" = "$current" ]; then
    return 0
  fi

  echo "[keys] rotate backend key for $id (version: $desired)"
  rm -f "$rd/id_rsa" "$rd/id_rsa.pub"
  ssh-keygen -t rsa -b 3072 -N "" -f "$rd/id_rsa" >/dev/null
  chmod 600 "$rd/id_rsa" "$rd/id_rsa.pub"
  printf '%s' "$desired" > "$marker"
  chmod 600 "$marker"
}

rootfs_img() {
  printf '%s/%s.img' "$IMAGE_DIR" "$(ct_name "$1")"
}

is_true() {
  printf '%s' "${1:-}" | grep -Eiq '^(1|true|yes|y|on)$'
}

ipv6_enabled() {
  local v
  v="${IPV6_ENABLED:-true}"
  is_true "$v"
}

keep_failed_resources() {
  local v
  v="${DEBUG_MODE:-false}"
  is_true "$v"
}

ipv6_mask() {
  echo "${IPV6_MASK:-128}"
}

gen_ipv6_suffix() {
  od -An -N8 -tx2 /dev/urandom | awk '{printf "%s:%s:%s:%s",$1,$2,$3,$4}'
}

resolve_ipv6_prefix() {
  local configured addr prefix

  ipv6_enabled || {
    echo "ipv6 disabled" >&2
    return 1
  }

  configured="${IPV6_PREFIX:-}"
  if [ -n "$configured" ] && [ "$configured" != "auto" ]; then
    configured="${configured%%/*}"
    prefix="$(printf '%s' "$configured" | awk -F: 'NF>=4 {print $1 ":" $2 ":" $3 ":" $4}')"
    [ -n "$prefix" ] || {
      echo "failed to derive IPv6 prefix from configured IPV6_PREFIX: $configured" >&2
      return 1
    }
    echo "$prefix"
    return 0
  fi

  addr="$(ip -6 addr show dev "$IPV6_DEV" scope global 2>/dev/null | awk '/inet6/ {print $2; exit}' | cut -d/ -f1)"
  [ -n "$addr" ] || {
    echo "failed to detect IPv6 global address on $IPV6_DEV" >&2
    return 1
  }

  prefix="$(printf '%s' "$addr" | awk -F: 'NF>=4 {print $1 ":" $2 ":" $3 ":" $4}')"
  [ -n "$prefix" ] || {
    echo "failed to derive IPv6 prefix from address: $addr" >&2
    return 1
  }

  echo "$prefix"
}

get_ipv6() {
  local id="$1" rd ip prefix
  rd="$(route_dir "$id")"
  mkdir -p "$rd"

  ip="$(cfg "$id" ipv6)"

  if [ "$ip" = "auto" ] || [ -z "$ip" ]; then
    if [ -s "$rd/ipv6_addr" ]; then
      cat "$rd/ipv6_addr"
      return
    fi

    prefix="$(resolve_ipv6_prefix)" || return 1

    while true; do
      ip="${prefix}:$(gen_ipv6_suffix)"
      if ! grep -Rqs "$ip" "$SSHPIPER_TENANT_ROOT" 2>/dev/null; then
        echo "$ip" > "$rd/ipv6_addr"
        chmod 600 "$rd/ipv6_addr"
        echo "$ip"
        return
      fi
    done
  else
    echo "$ip" > "$rd/ipv6_addr"
    chmod 600 "$rd/ipv6_addr"
    echo "$ip"
  fi
}

bridge_ll() {
  ip -6 addr show dev "$BRIDGE" scope link \
    | awk '/inet6 fe80/ {print $2}' \
    | cut -d/ -f1 \
    | head -1
}

resolve_uplink_dev() {
  # Priority: explicit IPV4_DEV -> explicit UPLINK_DEV -> default route device
  if [ -n "${IPV4_DEV:-}" ]; then
    echo "$IPV4_DEV"
    return 0
  fi

  if [ -n "${UPLINK_DEV:-}" ]; then
    echo "$UPLINK_DEV"
    return 0
  fi

  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

resolve_dns_servers() {
  local configured host_dns

  configured="${DNS_SERVERS:-}"
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured" | tr ',;' '  ' | awk '{for(i=1;i<=NF;i++) print $i}'
    return 0
  fi

  host_dns="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n 3)"
  if [ -n "$host_dns" ]; then
    printf '%s\n' "$host_dns"
    return 0
  fi

  printf '%s\n' 223.5.5.5 119.29.29.29
}

configure_container_dns() {
  local ct="$1" tmp ns has_dns
  tmp="$(mktemp)"
  has_dns=0

  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    has_dns=1
    printf 'nameserver %s\n' "$ns" >> "$tmp"
  done < <(resolve_dns_servers)

  if [ "$has_dns" -eq 0 ]; then
    printf 'nameserver 223.5.5.5\n' > "$tmp"
    printf 'nameserver 119.29.29.29\n' >> "$tmp"
  fi

  lxc-attach -n "$ct" -- sh -lc 'cat > /etc/resolv.conf' < "$tmp"
  rm -f "$tmp"
}

ensure_network() {
  local uplink err

  if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    command -v modprobe >/dev/null 2>&1 && modprobe bridge >/dev/null 2>&1 || true
    if ! err="$(ip link add "$BRIDGE" type bridge 2>&1)"; then
      echo "failed to create bridge $BRIDGE" >&2
      [ -n "$err" ] && echo "$err" >&2
      if printf '%s' "$err" | grep -qi 'Unknown device type'; then
        echo "hint: bridge module is unavailable in current kernel; reboot and retry apply" >&2
      fi
      return 1
    fi
  fi
  ip link set "$BRIDGE" up
  ip addr add "$IPV4_CIDR" dev "$BRIDGE" 2>/dev/null || true

  uplink="$(resolve_uplink_dev)"
  [ -n "$uplink" ] || {
    echo "failed to detect IPv4 uplink interface; set IPV4_DEV in config" >&2
    return 1
  }

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ipv6_enabled; then
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -C POSTROUTING -s "$IPV4_NET" -o "$uplink" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$IPV4_NET" -o "$uplink" -j MASQUERADE

    iptables -C FORWARD -i "$BRIDGE" -o "$uplink" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$BRIDGE" -o "$uplink" -j ACCEPT

    iptables -C FORWARD -i "$uplink" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$uplink" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  if ipv6_enabled; then
    sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null
    sysctl -w net.ipv6.conf."$IPV6_DEV".proxy_ndp=1 >/dev/null
  fi
}

ensure_dnsmasq() {
  rc-service lxc-dnsmasq start >/dev/null 2>&1 || true
}

restore_ipv6_for() {
  local id="$1" ip
  ipv6_enabled || return 0

  ip="$(get_ipv6 "$id")"
  ip -6 route replace "${ip}/128" dev "$BRIDGE"
  ip -6 neigh add proxy "$ip" dev "$IPV6_DEV" 2>/dev/null || true
}

cleanup_ipv6_for() {
  local id="$1" rd ip
  ipv6_enabled || return 0

  rd="$(route_dir "$id")"
  [ -f "$rd/ipv6_addr" ] || return 0

  ip="$(cat "$rd/ipv6_addr")"
  [ -n "$ip" ] || return 0

  ip -6 route del "${ip}/128" dev "$BRIDGE" 2>/dev/null || true
  ip -6 neigh del proxy "$ip" dev "$IPV6_DEV" 2>/dev/null || true
}

ensure_container_ipv6_route() {
  local id="$1" ct ll
  ipv6_enabled || return 0

  ct="$(ct_name "$id")"
  ll="$(bridge_ll)"

  [ -n "$ll" ] || {
    echo "failed to detect bridge link-local IPv6" >&2
    return 1
  }

  lxc-attach -n "$ct" -- ip -6 route replace default via "$ll" dev eth0 || true
  configure_container_dns "$ct"
}

sync_user_keys() {
  local id="$1" rd keydir keynames keyname value entry prefix
  rd="$(route_dir "$id")"
  keydir="$rd/authorized_keys.d"

  mkdir -p "$keydir"
  rm -f "$keydir"/*.pub 2>/dev/null || true

  keynames="$(cfg "$id" keys)"

  if [ -z "$keynames" ]; then
    prefix="${id}.keys."
    for entry in "${!USER_CFG[@]}"; do
      case "$entry" in
        "$prefix"*)
          keyname="${entry#$prefix}"
          [ -n "$keyname" ] || continue
          if [ -n "$keynames" ]; then
            keynames="${keynames} ${keyname}"
          else
            keynames="$keyname"
          fi
          ;;
      esac
    done
  fi

  for keyname in $keynames; do
    keyname="$(printf '%s' "$keyname" | tr 'A-Z' 'a-z')"
    value="$(cfg "$id" "key_${keyname}")"
    [ -n "$value" ] || value="$(cfg "$id" "keys.${keyname}")"
    [ -n "$value" ] || continue

    printf '%s\n' "$value" \
      | sed 's/\r$//' \
      | sed '/^[[:space:]]*$/d' \
      > "$keydir/${keyname}.pub"

    chmod 600 "$keydir/${keyname}.pub"
  done
}

rebuild_keys() {
  local id="$1" ct rd keydir backend_pub route_auth tmp f
  ct="$(ct_name "$id")"
  rd="$(route_dir "$id")"
  keydir="$rd/authorized_keys.d"
  backend_pub="$rd/id_rsa.pub"
  route_auth="$rd/authorized_keys"

  mkdir -p "$keydir"

  : > "$route_auth"
  for f in "$keydir"/*.pub; do
    [ -f "$f" ] || continue
    cat "$f" >> "$route_auth"
  done
  chmod 600 "$route_auth"

  [ -f "$backend_pub" ] || { echo "backend pubkey not found: $backend_pub" >&2; return 1; }

  tmp="$(mktemp)"
  cat "$backend_pub" "$route_auth" > "$tmp"

  lxc-attach -n "$ct" -- sh -lc '
set -e
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
' < "$tmp"

  rm -f "$tmp"
}

container_ipv4() {
  lxc-info -n "$1" -iH 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true
}

wait_ipv4() {
  local ct="$1" ip i
  for i in $(seq 1 30); do
    ip="$(container_ipv4 "$ct")"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 1
  done
  return 1
}

container_host_veth() {
  local ct="$1" ifindex host_dev

  ifindex="$(lxc-attach -n "$ct" -- sh -lc 'cat /sys/class/net/eth0/iflink' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$ifindex" ] || return 1

  host_dev="$(ip -o link | awk -F': ' -v idx="$ifindex" '$1 == idx {print $2; exit}' | sed 's/@.*//')"
  [ -n "$host_dev" ] || return 1

  printf '%s' "$host_dev"
}

apply_bandwidth_limit_for() {
  local id="$1" ct dev up down
  ct="$(ct_name "$id")"
  up="$(cfg "$id" bandwidth_up)"
  down="$(cfg "$id" bandwidth_down)"

  if [ -z "$up" ] && [ -z "$down" ]; then
    return 0
  fi

  dev="$(container_host_veth "$ct")" || {
    echo "failed to resolve host veth for $ct" >&2
    return 1
  }

  if [ -n "$down" ]; then
    tc qdisc replace dev "$dev" root tbf rate "$down" burst 128kbit latency 50ms
  else
    tc qdisc del dev "$dev" root 2>/dev/null || true
  fi

  if [ -n "$up" ]; then
    tc qdisc replace dev "$dev" handle ffff: ingress
    tc filter replace dev "$dev" parent ffff: protocol all prio 1 u32 match u32 0 0 police rate "$up" burst 128k drop flowid :1
  else
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
  fi
}

write_proxy_service() {
  local svc="$1" host_ip="$2" host_port="$3" target_ip="$4" target_port="$5"
  local file="/etc/init.d/${svc}"

  cat > "$file" <<EOF2
#!/sbin/openrc-run

name="${svc}"
description="TCP proxy ${host_ip}:${host_port} -> ${target_ip}:${target_port}"

command="/usr/bin/socat"
command_args="TCP-LISTEN:${host_port},bind=${host_ip},fork,reuseaddr TCP:${target_ip}:${target_port}"
command_background="yes"
pidfile="/run/${svc}.pid"

depend() {
  need net
}
EOF2

  chmod +x "$file"
  rc-update add "$svc" default >/dev/null 2>&1 || true
  rc-service "$svc" restart >/dev/null 2>&1 || true
}

remove_proxy_services_for() {
  local id="$1" ct svc name
  ct="$(ct_name "$id")"

  for svc in /etc/init.d/lxc-"${ct}"-*; do
    [ -f "$svc" ] || continue
    name="$(basename "$svc")"
    rc-service "$name" stop >/dev/null 2>&1 || true
    rc-update del "$name" default >/dev/null 2>&1 || true
    rm -f "$svc" "/run/${name}.pid"
  done
}

ensure_proxies_for() {
  local id="$1" ct ip ssh_port ports pair hp cp svc name
  declare -A expected_services

  ct="$(ct_name "$id")"
  ip="$(wait_ipv4 "$ct")"

  expected_services["lxc-${ct}-ssh"]=1

  ports="$(cfg "$id" ports)"
  for pair in $ports; do
    hp="${pair%%:*}"
    [ -n "$hp" ] || continue
    expected_services["lxc-${ct}-${hp}"]=1
  done

  for svc in /etc/init.d/lxc-"${ct}"-*; do
    [ -f "$svc" ] || continue
    name="$(basename "$svc")"
    if [ -z "${expected_services[$name]:-}" ]; then
      rc-service "$name" stop >/dev/null 2>&1 || true
      rc-update del "$name" default >/dev/null 2>&1 || true
      rm -f "$svc" "/run/${name}.pid"
    fi
  done

  ssh_port="$(cfg "$id" ssh_port)"
  write_proxy_service "lxc-${ct}-ssh" "10.10.0.1" "$ssh_port" "$ip" "22"

  for pair in $ports; do
    hp="${pair%%:*}"
    cp="${pair##*:}"
    write_proxy_service "lxc-${ct}-${hp}" "0.0.0.0" "$hp" "$ip" "$cp"
  done
}

install_sshpiper() {
  local version url tmp os arch

  version="${SSHPIPER_VERSION:-v1.5.3}"

  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64)
          url="https://github.com/tg123/sshpiper/releases/download/${version}/sshpiperd_with_plugins_linux_x86_64.tar.gz"
          ;;
        aarch64|arm64)
          url="https://github.com/tg123/sshpiper/releases/download/${version}/sshpiperd_with_plugins_linux_arm64.tar.gz"
          ;;
        *)
          echo "unsupported linux arch: $arch" >&2
          return 1
          ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64)
          url="https://github.com/tg123/sshpiper/releases/download/${version}/sshpiperd_with_plugins_darwin_arm64.tar.gz"
          ;;
        x86_64)
          url="https://github.com/tg123/sshpiper/releases/download/${version}/sshpiperd_with_plugins_darwin_x86_64.tar.gz"
          ;;
        *)
          echo "unsupported darwin arch: $arch" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "unsupported os: $os" >&2
      return 1
      ;;
  esac

  echo "[sshpiper] install ${version}"
  echo "[sshpiper] detected: ${os}/${arch}"
  echo "[sshpiper] url: ${url}"

  tmp="$(mktemp -d)"

  curl -L "$url" -o "$tmp/sshpiper.tar.gz"

  tar xzf "$tmp/sshpiper.tar.gz" -C "$tmp"

  mkdir -p "$(dirname "$SSHPIPER_BIN")"

  install -m755 \
    "$tmp/sshpiperd" \
    "$SSHPIPER_BIN"

  if [ -d "$tmp/plugins" ]; then
    rm -rf "$SSHPIPER_PLUGIN_DIR"
    cp -a "$tmp/plugins" "$SSHPIPER_PLUGIN_DIR"
    chmod +x "$SSHPIPER_PLUGIN_DIR"/* || true
  fi

  rm -rf "$tmp"

  "$SSHPIPER_BIN" -v || true
}

agent_enabled() {
  local v
  v="${AGENT_ENABLED:-true}"
  is_true "$v"
}

render_agent_config() {
  mkdir -p "$(dirname "$AGENT_CONFIG")" "$(dirname "$AGENT_STATE_FILE")"

  cat > "$AGENT_CONFIG" <<EOF
ak: "${AGENT_AK:-your-ak}"
sk: "${AGENT_SK:-your-sk}"
signature_scope: "${AGENT_SIGNATURE_SCOPE:-lxc-platform-agent}"
auth_timestamp_skew_seconds: ${AGENT_AUTH_TIMESTAMP_SKEW_SECONDS:-300}
listen_addr: "${AGENT_LISTEN_ADDR:-:9108}"
metrics_path: "${AGENT_METRICS_PATH:-/metrics}"
api_base_path: "${AGENT_API_BASE_PATH:-/api/v1}"
container_interface: "${AGENT_CONTAINER_INTERFACE:-eth0}"
platform_state_dir: "${RUNTIME_DIR}/state/containers"
config_dir: "${CONFIG_DIR}"
image_dir: "${IMAGE_DIR}"
state_file: "${AGENT_STATE_FILE}"
EOF

  chmod 600 "$AGENT_CONFIG"
}

install_platform_agent() {
  local agent_src

  agent_src="${BASE_DIR}/agent"
  [ -d "$agent_src" ] || {
    echo "agent source not found: $agent_src" >&2
    return 1
  }

  mkdir -p "$(dirname "$AGENT_BIN")"

  echo "[agent] build binary"
  (
    cd "$agent_src"
    go build -o "$AGENT_BIN" ./cmd/lxc-platform-agent
  )

  chmod +x "$AGENT_BIN"
  render_agent_config
}

render_sniproxy() {
  mkdir -p "$(dirname "$SNIPROXY_CONF")" /var/log/sniproxy

  {
    echo 'user nobody'
    echo 'pidfile /run/sniproxy.pid'
    echo
    echo 'error_log {'
    echo '    filename /var/log/sniproxy/error.log'
    echo '    priority notice'
    echo '}'
    echo
    echo "listener [::]:${SNIPROXY_PORT} {"
    echo '    proto tls'
    echo '}'
    echo
    echo 'table {'

    for file in "$CONFIG_DIR"/*.yaml; do
      [ -f "$file" ] || continue
      id="$(basename "$file" .yaml)"
      local sni_routes item host port
      sni_routes="$(cfg "$id" sni)"
      for item in $sni_routes; do
        host="${item%%:*}"
        port="${item##*:}"
        echo "    ${host} 127.0.0.1:${port}"
      done
    done

    echo '}'
  } > "$SNIPROXY_CONF"

  mkdir -p /etc/sniproxy
  ln -sf "$SNIPROXY_CONF" /etc/sniproxy/sniproxy.conf

  if [ -f /run/sniproxy.pid ] && kill -0 "$(cat /run/sniproxy.pid)" 2>/dev/null; then
    kill -HUP "$(cat /run/sniproxy.pid)" || true
  else
    rc-service sniproxy restart >/dev/null 2>&1 || true
  fi
}

create_cleanup() {
  local id="$1" ct="$2" img="$3" rd="$4"
  echo
  echo "[ERROR] create failed, cleaning resources..."

  remove_proxy_services_for "$id"
  cleanup_ipv6_for "$id"

  lxc-stop -n "$ct" -k >/dev/null 2>&1 || true

  if mountpoint -q "/var/lib/lxc/${ct}/rootfs" 2>/dev/null; then
    umount "/var/lib/lxc/${ct}/rootfs" >/dev/null 2>&1 || \
    umount -l "/var/lib/lxc/${ct}/rootfs" >/dev/null 2>&1 || true
  fi

  lxc-destroy -n "$ct" >/dev/null 2>&1 || true
  rm -rf "/var/lib/lxc/${ct}"
  rm -f "$img"
  rm -rf "$rd"
  rm -f "$(container_state_file_by_id "$id")"

  render_sniproxy || true

  echo "[ERROR] cleanup done"
}

install_container_sshd() {
  local ct="$1"

  echo "[create] install sshd"
  configure_container_dns "$ct"
  lxc-attach -n "$ct" -- sh -lc '
set -e
udhcpc -i eth0 || true

if command -v apk >/dev/null 2>&1; then
  for i in $(seq 1 10); do
    if apk update; then
      break
    fi
    [ "$i" -lt 10 ] || exit 1
    sleep 2
  done

  apk add --no-cache openssh bash curl

  ssh-keygen -A

  sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
  sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
  sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
  sed -i "s/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/" /etc/ssh/sshd_config
  sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config

  rc-update add sshd default || true
  rc-service sshd restart || /usr/sbin/sshd
elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive

  if command -v dhclient >/dev/null 2>&1; then
    dhclient -v eth0 || true
  fi

  for i in $(seq 1 10); do
    if apt-get update; then
      break
    fi
    [ "$i" -lt 10 ] || exit 1
    sleep 2
  done

  apt-get install -y --no-install-recommends openssh-server bash curl ca-certificates

  mkdir -p /run/sshd
  ssh-keygen -A

  sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
  sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
  sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
  sed -i "s/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/" /etc/ssh/sshd_config
  sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  fi

  if command -v service >/dev/null 2>&1; then
    service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
  fi

  pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd
else
  echo "unsupported container package manager: need apk or apt-get" >&2
  exit 1
fi
'
}

create_container() {
  local id="$1" ct rd img disk mem cpu distro release arch ipv6 tmp_rootfs config ip mask
  ct="$(ct_name "$id")"
  rd="$(route_dir "$id")"
  img="$(rootfs_img "$id")"
  disk="$(cfg "$id" disk)"
  mem="$(cfg "$id" memory)"
  cpu="$(cfg "$id" cpu)"
  distro="$(cfg "$id" distro)"
  release="$(cfg "$id" release)"
  arch="$(cfg "$id" arch)"

  [ -n "$distro" ] || distro="$DEFAULT_DISTRO"
  [ -n "$release" ] || release="$DEFAULT_RELEASE"
  [ -n "$arch" ] || arch="$DEFAULT_ARCH"

  if [ -d "/var/lib/lxc/$ct" ]; then
    echo "container exists: $ct"

    start_container "$id"

    return 0
  fi

  trap 'code=$?; trap - EXIT; if [ "$code" -ne 0 ]; then if keep_failed_resources; then echo; echo "[ERROR] create failed, debug mode enabled: resources kept"; echo "  ct dir: /var/lib/lxc/'"$ct"'"; echo "  image:  '"$img"'"; echo "  route:  '"$rd"'"; else create_cleanup "'"$id"'" "'"$ct"'" "'"$img"'" "'"$rd"'"; fi; fi; exit "$code"' EXIT

  ensure_network
  ensure_dnsmasq
  ensure_route_dir "$id"
  rotate_backend_key_if_needed "$id"
  sync_user_keys "$id"

  ipv6=""
  mask=""
  if ipv6_enabled; then
    ipv6="$(get_ipv6 "$id")"
    mask="$(ipv6_mask)"
  fi

  mkdir -p "$IMAGE_DIR"

  echo "[create] rootfs image: $img size=$disk"
  truncate -s "$disk" "$img"
  mkfs.ext4 -F "$img" >/dev/null

  [ -x /usr/share/lxc/templates/lxc-download ] || {
    echo "missing LXC download template: install package lxc-download" >&2
    return 1
  }

  echo "[create] lxc-create: $ct"
  lxc-create -n "$ct" -t download -- -d "$distro" -r "$release" -a "$arch"

  echo "[create] move rootfs into loop image"
  tmp_rootfs="/tmp/${ct}-rootfs.$$"
  mkdir -p "$tmp_rootfs"
  rsync -aHAX "/var/lib/lxc/${ct}/rootfs/" "$tmp_rootfs/"

  rm -rf "/var/lib/lxc/${ct}/rootfs"
  mkdir -p "/var/lib/lxc/${ct}/rootfs"

  mount -o loop "$img" "/var/lib/lxc/${ct}/rootfs"
  rsync -aHAX "$tmp_rootfs/" "/var/lib/lxc/${ct}/rootfs/"
  rm -rf "$tmp_rootfs"

  config="/var/lib/lxc/${ct}/config"

  cat >> "$config" <<EOF2

# managed by lxc-platform
lxc.start.auto = 1
lxc.start.delay = 3

lxc.net.0.type = veth
lxc.net.0.link = ${BRIDGE}
lxc.net.0.flags = up
lxc.net.0.name = eth0
EOF2

  if ipv6_enabled; then
    cat >> "$config" <<EOF2
lxc.net.0.ipv6.address = ${ipv6}/${mask}
EOF2
  fi

  if [ -n "$mem" ]; then
    cat >> "$config" <<EOF2

lxc.cgroup2.memory.max = ${mem}
EOF2
  fi

  cat >> "$config" <<EOF2
lxc.cgroup2.pids.max = 128
EOF2

  echo "[create] start container"
  lxc-start -n "$ct" -d
  sleep 6

  restore_ipv6_for "$id"
  ensure_container_ipv6_route "$id"

  install_container_sshd "$ct"

  rebuild_keys "$id"
  ip="$(wait_ipv4 "$ct")"
  apply_bandwidth_limit_for "$id"
  ensure_proxies_for "$id"

  cat > "$rd/sshpiper_upstream" <<EOF2
root@10.10.0.1:$(cfg "$id" ssh_port)
EOF2
  chmod 600 "$rd/sshpiper_upstream"

  render_sniproxy
  write_container_state "$id" "$ip"

  trap - EXIT

  echo
  echo "created:"
  echo "  id:      $id"
  echo "  ct:      $ct"
  echo "  ipv4:    $ip"
  if ipv6_enabled; then
    echo "  ipv6:    $ipv6/$mask"
  fi
  echo "  route:   $(route_name "$id")"
  echo "  ssh:     10.10.0.1:$(cfg "$id" ssh_port)"
}

start_container() {
  local id="$1" ct img rootfs ip
  ct="$(ct_name "$id")"
  img="$(rootfs_img "$id")"
  rootfs="/var/lib/lxc/${ct}/rootfs"

  [ -d "/var/lib/lxc/$ct" ] || { echo "container not found: $ct" >&2; exit 1; }
  [ -f "$img" ] || { echo "rootfs image not found: $img" >&2; exit 1; }

  ensure_network
  ensure_dnsmasq
  ensure_route_dir "$id"
  rotate_backend_key_if_needed "$id"

  mkdir -p "$rootfs"
  mountpoint -q "$rootfs" || mount -o loop "$img" "$rootfs"

  if [ "$(lxc-info -n "$ct" | awk -F: '/State/ {gsub(/ /, "", $2); print $2}')" != "RUNNING" ]; then
    lxc-start -n "$ct" -d
  fi

  ip="$(wait_ipv4 "$ct")"
  restore_ipv6_for "$id"
  ensure_container_ipv6_route "$id"
  sync_user_keys "$id"
  rebuild_keys "$id"
  apply_bandwidth_limit_for "$id"
  ensure_proxies_for "$id"
  write_container_state "$id" "$ip"

  echo "started: $ct"
}

stop_container() {
  local id="$1" ct rootfs
  ct="$(ct_name "$id")"
  rootfs="/var/lib/lxc/${ct}/rootfs"

  remove_proxy_services_for "$id"

  if [ -d "/var/lib/lxc/$ct" ]; then
    lxc-stop -n "$ct" >/dev/null 2>&1 || true
  fi

  if mountpoint -q "$rootfs" 2>/dev/null; then
    umount "$rootfs" || umount -l "$rootfs" || true
  fi

  write_container_state "$id" ""

  echo "stopped: $ct"
}

delete_container() {
  local id="$1" ct rd img rootfs
  ct="$(ct_name "$id")"
  rd="$(route_dir "$id")"
  img="$(rootfs_img "$id")"
  rootfs="/var/lib/lxc/${ct}/rootfs"

  remove_proxy_services_for "$id"
  cleanup_ipv6_for "$id"

  if [ -d "/var/lib/lxc/$ct" ]; then
    lxc-stop -n "$ct" -k >/dev/null 2>&1 || true
  fi

  if mountpoint -q "$rootfs" 2>/dev/null; then
    umount "$rootfs" || umount -l "$rootfs" || true
  fi

  lxc-destroy -n "$ct" >/dev/null 2>&1 || true
  rm -rf "/var/lib/lxc/$ct"
  rm -f "$img"
  rm -rf "$rd"
  rm -f "$(container_state_file_by_ct "$ct")"

  render_sniproxy

  echo "deleted: $ct"
}

apply_all() {
  ensure_network
  ensure_dnsmasq

  # create/update from configs (ENABLED controls desired state)
  for file in "$CONFIG_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    id="$(basename "$file" .yaml)"

    enabled="$(cfg "$id" enabled)"
    if [ -n "$enabled" ] && ! printf '%s' "$enabled" | grep -Eiq '^(y|yes|1|true)$'; then
      echo "ensuring stopped (disabled): $id"
      stop_container "$id" || true
      continue
    fi

    create_container "$id"
  done

  # prune containers that no longer have a config
  declare -A configured_cts
  for file in "$CONFIG_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    id="$(basename "$file" .yaml)"
    ct="$(ct_name "$id")"
    [ -n "$ct" ] && configured_cts["$ct"]=1
  done

  declare -A existing_cts
  for img in "$IMAGE_DIR"/*.img; do
    [ -f "$img" ] || continue
    name="$(basename "$img" .img)"
    existing_cts["$name"]=1
  done
  for dir in /var/lib/lxc/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    existing_cts["$name"]=1
  done

  for ct in "${!existing_cts[@]}"; do
    [ -n "$ct" ] || continue
    if [ -z "${configured_cts[$ct]:-}" ]; then
      echo "pruning container missing config: $ct"
      delete_container_by_ct "$ct"
    fi
  done

  render_sniproxy
}

delete_container_by_ct() {
  local ct="$1" rd img rootfs ip
  rd="$(route_dir_by_ct "$ct")"
  img="$IMAGE_DIR/${ct}.img"
  rootfs="/var/lib/lxc/${ct}/rootfs"

  # stop proxies
  for svc in /etc/init.d/lxc-"${ct}"-*; do
    [ -f "$svc" ] || continue
    name="$(basename "$svc")"
    rc-service "$name" stop >/dev/null 2>&1 || true
    rc-update del "$name" default >/dev/null 2>&1 || true
    rm -f "$svc" "/run/${name}.pid"
  done

  # cleanup ipv6 route if we can find stored addr
  if [ -f "$rd/ipv6_addr" ]; then
    ip="$(cat "$rd/ipv6_addr")"
    ip -6 route del "${ip}/128" dev "$BRIDGE" 2>/dev/null || true
    ip -6 neigh del proxy "$ip" dev "$IPV6_DEV" 2>/dev/null || true
  fi

  if [ -d "/var/lib/lxc/$ct" ]; then
    lxc-stop -n "$ct" -k >/dev/null 2>&1 || true
  fi

  if mountpoint -q "$rootfs" 2>/dev/null; then
    umount "$rootfs" || umount -l "$rootfs" || true
  fi

  lxc-destroy -n "$ct" >/dev/null 2>&1 || true
  rm -rf "/var/lib/lxc/$ct"
  rm -f "$img"
  rm -rf "$rd"
  rm -f "$(container_state_file_by_ct "$ct")"

  render_sniproxy

  echo "deleted (by ct): $ct"
}

status_one() {
  local id="$1" ct rd img ipv6
  ct="$(ct_name "$id")"
  rd="$(route_dir "$id")"
  img="$(rootfs_img "$id")"

  echo "== $id =="
  echo "container: $ct"
  lxc-info -n "$ct" 2>/dev/null || echo "not found"

  [ -f "$rd/ipv6_addr" ] && ipv6="$(cat "$rd/ipv6_addr")" || ipv6=""
  [ -n "${ipv6:-}" ] && echo "ipv6: $ipv6/$(ipv6_mask)"

  [ -f "$img" ] && ls -lh "$img"

  echo "ports:"
  for svc in /etc/init.d/lxc-"${ct}"-*; do
    [ -f "$svc" ] || continue
    echo "  $(basename "$svc")"
    grep '^command_args=' "$svc" | sed 's/^/    /'
  done

  echo
}

status_all() {
  for file in "$CONFIG_DIR"/*.yaml; do
    [ -f "$file" ] || continue
    id="$(basename "$file" .yaml)"
    status_one "$id"
  done

  echo "sniproxy:"
  grep -v '^[[:space:]]*$' "$SNIPROXY_CONF" 2>/dev/null || true
}

bootstrap() {
  apk update
  apk upgrade --available

  apk add --no-cache \
    bash \
    curl \
    iproute2 \
    iptables \
    iptables-openrc \
    kmod \
    linux-virt \
    lxcfs \
    openssh \
    dnsmasq \
    sniproxy \
    socat \
    rsync \
    e2fsprogs \
    go \
    lxc \
    lxc-download \
    inotify-tools

  if ! ensure_network; then
    echo "[bootstrap] bridge setup failed; reboot the host and rerun bootstrap" >&2
    return 1
  fi

  SSHPIPER_VERSION="${SSHPIPER_VERSION:-v1.5.3}"

  mkdir -p \
    "$CONFIG_DIR" \
    "$SSHPIPER_BASE" \
    "$SSHPIPER_ROUTE_ROOT" \
    "$SSHPIPER_TENANT_ROOT" \
    "$SSHPIPER_PLUGIN_DIR" \
    "$AGENT_RUNTIME_DIR" \
    "$(dirname "$AGENT_BIN")" \
    "$(dirname "$AGENT_CONFIG")" \
    "$(dirname "$AGENT_STATE_FILE")" \
    "$(dirname "$SSHPIPER_HOSTKEY")" \
    "$IMAGE_DIR" \
    "$RUNTIME_DIR/generated" \
    /var/log/sniproxy \
    /etc/sniproxy

  echo "[bootstrap] install sshpiper"
  install_sshpiper

  if agent_enabled; then
    echo "[bootstrap] build platform agent"
    install_platform_agent
  fi

  if [ ! -f "$SSHPIPER_HOSTKEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSHPIPER_HOSTKEY" >/dev/null
  fi

  cat > /etc/init.d/lxc-dnsmasq <<EOF
#!/sbin/openrc-run

name="lxc-dnsmasq"

command="/usr/sbin/dnsmasq"

command_args="
  --keep-in-foreground
  --interface=${BRIDGE}
  --except-interface=lo
  --bind-dynamic
  --dhcp-range=${DHCP_RANGE}
  --port=0
  --pid-file=/run/dnsmasq-lxcbr0.pid
"

command_background="yes"

pidfile="/run/dnsmasq-lxcbr0.pid"

depend() {
  need net
}
EOF

  chmod +x /etc/init.d/lxc-dnsmasq

  cat > /etc/init.d/sniproxy <<EOF
#!/sbin/openrc-run

name="sniproxy"

command="/usr/sbin/sniproxy"

command_args="-c /etc/sniproxy/sniproxy.conf"

command_background="yes"

pidfile="/run/sniproxy.pid"

depend() {
  need net
}
EOF

  chmod +x /etc/init.d/sniproxy

  cat > /etc/init.d/sshpiperd <<EOF
#!/sbin/openrc-run

name="sshpiperd"
description="SSH identity router"

command="${SSHPIPER_BIN}"
command_args="--address ${SSHPIPER_ADDRESS} --port ${SSHPIPER_PORT} -i ${SSHPIPER_HOSTKEY} --server-key-generate-mode notexist ${SSHPIPER_WORKINGDIR_PLUGIN} --root ${SSHPIPER_TENANT_ROOT}"

command_background="yes"

pidfile="/run/sshpiperd.pid"

output_log="/var/log/sshpiperd.log"
error_log="/var/log/sshpiperd.err"

depend() {
  need net
  after lxc-platform
}
EOF

  chmod +x /etc/init.d/sshpiperd

  if agent_enabled; then
    cat > /etc/init.d/lxc-platform-agent <<EOF
#!/sbin/openrc-run

name="lxc-platform-agent"
description="LXC platform metrics agent"

command="${AGENT_BIN}"
command_args="-config ${AGENT_CONFIG}"
command_background="yes"

pidfile="/run/lxc-platform-agent.pid"

output_log="${AGENT_LOG}"
error_log="${AGENT_LOG}"

depend() {
  need net lxc-platform
}
EOF

    chmod +x /etc/init.d/lxc-platform-agent
  fi

  cat > /etc/init.d/lxc-platform <<EOF
#!/sbin/openrc-run

name="lxc-platform"

depend() {
  need net lxc-dnsmasq
}

start() {
  ebegin "Applying LXC platform"
  ${BASE_DIR}/lxc-platform.sh apply
  eend \$?
}
EOF

  chmod +x /etc/init.d/lxc-platform

  cat > /usr/local/bin/lxc-platform-watchd <<EOF
#!/usr/bin/env sh
while true; do
  if inotifywait -r -q -e close_write,create,delete,move "${CONFIG_DIR}" 2>/dev/null; then
    sleep 3
    "${BASE_DIR}/lxc-platform.sh" apply || true
  else
    sleep 5
  fi
done
EOF

  chmod +x /usr/local/bin/lxc-platform-watchd

  cat > /etc/init.d/lxc-platform-watch <<EOF
#!/sbin/openrc-run

name="lxc-platform-watch"
description="Watch lxc.d for changes and auto-apply"

command="/usr/local/bin/lxc-platform-watchd"
command_background="yes"
pidfile="/run/lxc-platform-watch.pid"

output_log="/var/log/lxc-platform-watch.log"
error_log="/var/log/lxc-platform-watch.log"

depend() {
  need lxc-platform
}
EOF

  chmod +x /etc/init.d/lxc-platform-watch

  cat > /etc/local.d/lxc-network.start <<EOF
#!/bin/sh
ip link show "${BRIDGE}" >/dev/null 2>&1 || ip link add "${BRIDGE}" type bridge
ip link set "${BRIDGE}" up
ip addr add "${IPV4_CIDR}" dev "${BRIDGE}" 2>/dev/null || true

UPLINK_IF="${IPV4_DEV:-${UPLINK_DEV:-}}"
if [ -z "\${UPLINK_IF}" ]; then
  UPLINK_IF="\$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); exit}}')"
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if printf '%s' "${IPV6_ENABLED:-true}" | grep -Eiq '^(1|true|yes|y|on)$'; then
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
fi

if command -v iptables >/dev/null 2>&1 && [ -n "\${UPLINK_IF}" ]; then
  iptables -t nat -C POSTROUTING -s "${IPV4_NET}" -o "\${UPLINK_IF}" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "${IPV4_NET}" -o "\${UPLINK_IF}" -j MASQUERADE

  iptables -C FORWARD -i "${BRIDGE}" -o "\${UPLINK_IF}" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "${BRIDGE}" -o "\${UPLINK_IF}" -j ACCEPT

  iptables -C FORWARD -i "\${UPLINK_IF}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "\${UPLINK_IF}" -o "${BRIDGE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

if printf '%s' "${IPV6_ENABLED:-true}" | grep -Eiq '^(1|true|yes|y|on)$'; then
  sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null
  sysctl -w net.ipv6.conf."${IPV6_DEV}".proxy_ndp=1 >/dev/null
fi

exit 0
EOF

  chmod +x /etc/local.d/lxc-network.start

  rc-update add local default >/dev/null 2>&1 || true
  rc-update add iptables default >/dev/null 2>&1 || true
  rc-update add lxcfs default >/dev/null 2>&1 || true
  rc-update add lxc-dnsmasq default >/dev/null 2>&1 || true
  rc-update add sniproxy default >/dev/null 2>&1 || true
  rc-update add sshpiperd default >/dev/null 2>&1 || true
  if agent_enabled; then
    rc-update add lxc-platform-agent default >/dev/null 2>&1 || true
  fi
  rc-update add lxc-platform default >/dev/null 2>&1 || true
  rc-update add lxc-platform-watch default >/dev/null 2>&1 || true

  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules-save || true
  fi
  render_sniproxy

  rc-service lxcfs restart >/dev/null 2>&1 || rc-service lxcfs start >/dev/null 2>&1 || true
  rc-service lxc-dnsmasq restart >/dev/null 2>&1 || rc-service lxc-dnsmasq start >/dev/null 2>&1 || true
  rc-service sniproxy restart >/dev/null 2>&1 || rc-service sniproxy start >/dev/null 2>&1 || true
  rc-service sshpiperd restart >/dev/null 2>&1 || rc-service sshpiperd start >/dev/null 2>&1 || true
  if agent_enabled; then
    rc-service lxc-platform-agent restart >/dev/null 2>&1 || rc-service lxc-platform-agent start >/dev/null 2>&1 || true
  fi
  rc-service lxc-platform-watch restart >/dev/null 2>&1 || rc-service lxc-platform-watch start >/dev/null 2>&1 || true

  echo "[bootstrap] done"
}

doctor() {
  local prefix agent_listen

  echo "[bridge]"
  ip addr show "$BRIDGE" || true

  echo
  echo "[dnsmasq]"
  rc-service lxc-dnsmasq status || true
  pgrep -a dnsmasq || true

  echo
  echo "[ipv6 proxy]"
  ip -6 neigh show proxy || true

  echo
  echo "[ipv6 route]"
  prefix="$(resolve_ipv6_prefix 2>/dev/null || true)"
  if [ -n "$prefix" ]; then
    ip -6 route | grep "$prefix" || true
  else
    ip -6 route || true
  fi

  echo
  echo "[sniproxy]"
  rc-service sniproxy status || true

  if agent_enabled; then
    echo
    echo "[agent]"
    rc-service lxc-platform-agent status || true
    pgrep -a -f "$AGENT_BIN" || true

    echo "binary: $AGENT_BIN"
    [ -x "$AGENT_BIN" ] || echo "missing binary"

    echo "config: $AGENT_CONFIG"
    [ -f "$AGENT_CONFIG" ] && sed -n '1,40p' "$AGENT_CONFIG" || echo "missing config"

    echo "state: $AGENT_STATE_FILE"
    [ -f "$AGENT_STATE_FILE" ] && ls -lh "$AGENT_STATE_FILE" || echo "state file not found yet"

    agent_listen="${AGENT_LISTEN_ADDR:-:9108}"
    echo "listen: $agent_listen"
    ss -lntp 2>/dev/null | grep -F "${agent_listen##*:}" || true
  fi

  echo
  echo "[lxc]"
  if command -v lxc-ls >/dev/null 2>&1; then
    lxc-ls -f || true
  elif command -v lxc-info >/dev/null 2>&1; then
    for dir in /var/lib/lxc/*; do
      [ -d "$dir" ] || continue
      lxc-info -n "$(basename "$dir")" || true
    done
  else
    echo "lxc tools not installed (missing lxc-ls/lxc-info)"
  fi
}

usage() {
  cat <<EOF2
Usage:
  $0 bootstrap
  $0 apply
  $0 status
  $0 doctor

Config:
  $CONFIG
EOF2
}

cmd="${1:-}"
case "$cmd" in
  bootstrap) bootstrap ;;
  apply) apply_all "${@:2}" ;;
  status) status_all ;;
  doctor) doctor ;;
  *) usage; exit 1 ;;
esac
