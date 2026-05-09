#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-/etc/sing-box/config.json}"
AUTO_DOWNLOAD_WARP_TOOLS="${AUTO_DOWNLOAD_WARP_TOOLS:-true}"
WARP_TOOL="${WARP_TOOL:-warp-yg}"
WARP_GO_BIN="${WARP_GO_BIN:-/root/warp-go/warp-go}"
WARP_GO_BASE="${WARP_GO_BASE:-/root/warp-go}"
WARP_YG_BASE="${WARP_YG_BASE:-/root/warp-yg}"
WARP_YG_REPO_URL="${WARP_YG_REPO_URL:-https://github.com/yonggekkk/warp-yg.git}"
WARP_YG_REPO_DIR="${WARP_YG_REPO_DIR:-$WARP_YG_BASE/source}"
WARP_YG_ACCOUNT_SOURCE="${WARP_YG_ACCOUNT_SOURCE:-auto}"
WGCF_BIN="${WGCF_BIN:-/root/wgcf/wgcf}"
WGCF_BASE="${WGCF_BASE:-/root/wgcf}"
LISTEN_PORT="${LISTEN_PORT:-443}"
WARP_INTERFACE_COUNT="${WARP_INTERFACE_COUNT:-}"
WARP_PROFILES_PER_INTERFACE="${WARP_PROFILES_PER_INTERFACE:-}"
EGRESS_INTERFACE_COUNT="${EGRESS_INTERFACE_COUNT:-}"
SECONDARY_NETPLAN_PATH="${SECONDARY_NETPLAN_PATH:-/etc/netplan/60-secondary-vnic.yaml}"
SECONDARY_VNIC_TABLE="${SECONDARY_VNIC_TABLE:-100}"
SECONDARY_VNIC_TABLE_BASE="${SECONDARY_VNIC_TABLE_BASE:-$SECONDARY_VNIC_TABLE}"
SECONDARY_VNIC_PRIORITY="${SECONDARY_VNIC_PRIORITY:-100}"
SECONDARY_VNIC_PRIORITY_BASE="${SECONDARY_VNIC_PRIORITY_BASE:-$SECONDARY_VNIC_PRIORITY}"
WARP_YG_FAIL_MARKER=""
EGRESS_INTERFACE="${EGRESS_INTERFACE:-}"
EGRESS_1_INTERFACE="${EGRESS_1_INTERFACE:-}"
EGRESS_2_INTERFACE="${EGRESS_2_INTERFACE:-}"

declare -A USER_PASSWORDS
declare -A EGRESS_IFACES
declare -A EGRESS_V4_ADDRS
declare -A EGRESS_V6_ADDRS
declare -A WARP_PROFILE_PATHS
declare -A WARP_SINGBOX_PATHS
declare -A WARP_KEYS
declare -A WARP_ADDRS
declare -A WARP_PEERS
declare -A WARP_ENDPOINTS
declare -A WARP_PORTS
declare -A WARP_RESERVED
declare -a EGRESS_INTERFACE_OPTIONS

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

need_fetch_cmd() {
  if command -v curl >/dev/null 2>&1; then
    FETCH_CMD="curl"
  elif command -v wget >/dev/null 2>&1; then
    FETCH_CMD="wget"
  else
    die "Missing command: curl or wget"
  fi
}

fetch_url() {
  local url="$1"
  local output="${2:-}"

  if [[ "$FETCH_CMD" == "curl" ]]; then
    if [[ -n "$output" ]]; then
      curl -fsSL --retry 3 --connect-timeout 20 -o "$output" "$url"
    else
      curl -fsL --retry 3 --connect-timeout 20 "$url"
    fi
  else
    if [[ -n "$output" ]]; then
      wget -O "$output" "$url"
    else
      wget -qO- "$url"
    fi
  fi
}

prompt() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$label: " value
  fi

  [[ -n "$value" ]] || die "$label is required"
  printf -v "$var_name" '%s' "$value"
}

config_json_value() {
  local key="$1"

  [[ -f "$CONFIG_PATH" ]] || return 0
  awk -v key="$key" '
    $0 ~ "\"" key "\"" {
      line = $0
      sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
      sub("\".*", "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH"
}

config_user_password() {
  local user_name="$1"

  [[ -f "$CONFIG_PATH" ]] || return 0
  awk -v user_name="$user_name" '
    /"name"[[:space:]]*:/ {
      line = $0
      sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      current_name = line
    }
    current_name == user_name && /"password"[[:space:]]*:/ {
      line = $0
      sub(/.*"password"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH"
}

config_interface_count() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  awk '
    /"(name|tag)"[[:space:]]*:[[:space:]]*"(direct|warp)-v[46]-[0-9]+"/ {
      line = $0
      sub(/^.*"(direct|warp)-v[46]-/, "", line)
      sub(/".*$/, "", line)
      if (line + 0 > max) {
        max = line + 0
      }
    }
    END {
      if (max > 0) {
        print max
      }
    }
  ' "$CONFIG_PATH"
}

config_bind_interface() {
  local tag="$1"
  local alt_tag="$tag"

  if [[ "$tag" =~ ^warp-ipv([46])-([0-9]+)$ ]]; then
    alt_tag="warp-v${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  elif [[ "$tag" =~ ^warp-v([46])-([0-9]+)$ ]]; then
    alt_tag="warp-ipv${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  fi

  [[ -f "$CONFIG_PATH" ]] || return 0
  awk -v tag="$tag" -v alt_tag="$alt_tag" '
    /"tag"[[:space:]]*:/ {
      line = $0
      sub(/.*"tag"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      found = (line == tag || line == alt_tag)
    }
    found && /"bind_interface"[[:space:]]*:/ {
      line = $0
      sub(/.*"bind_interface"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$CONFIG_PATH"
}

config_unique_bind_interfaces() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  awk '
    /"bind_interface"[[:space:]]*:/ {
      line = $0
      sub(/.*"bind_interface"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      if (!(line in seen)) {
        seen[line] = 1
        print line
      }
    }
  ' "$CONFIG_PATH"
}

validate_positive_integer() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer"
}

legacy_user_name() {
  local user_name="$1"

  case "$user_name" in
    direct-v4-1) printf 'ipv4-1' ;;
    warp-v4-1) printf 'ipv4-2' ;;
    warp-v4-2) printf 'ipv4-3' ;;
    direct-v6-1) printf 'ipv6-1' ;;
    warp-v6-1) printf 'ipv6-2' ;;
    warp-v6-2) printf 'ipv6-3' ;;
  esac
}

user_password() {
  local user_name="$1"
  printf '%s' "${USER_PASSWORDS[$user_name]}"
}

warp_profile_tag() {
  local family="$1"
  local index="$2"

  printf 'warp-ipv%s-%s' "$family" "$index"
}

interface_address() {
  local family="$1"
  local interface="$2"

  if [[ "$family" == "4" ]]; then
    ip -o -4 addr show dev "$interface" scope global | awk 'NR == 1 { split($4, a, "/"); print a[1]; exit }'
  else
    ip -o -6 addr show dev "$interface" scope global | awk 'NR == 1 { split($4, a, "/"); print a[1]; exit }'
  fi
}

interface_ipv4_cidr() {
  local interface="$1"

  ip -o -4 addr show dev "$interface" scope global | awk 'NR == 1 { print $4; exit }'
}

ipv4_to_int() {
  local ip="$1"
  local a b c d
  local value

  IFS=. read -r a b c d <<< "$ip"
  for value in "$a" "$b" "$c" "$d"; do
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge 0 && "$value" -le 255 ]] || die "Invalid IPv4 address: $ip"
  done

  printf '%u' $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ipv4() {
  local value="$1"

  printf '%u.%u.%u.%u' \
    $(( (value >> 24) & 255 )) \
    $(( (value >> 16) & 255 )) \
    $(( (value >> 8) & 255 )) \
    $(( value & 255 ))
}

calculated_ipv4_gateway() {
  local cidr="$1"
  local ip prefix ip_int mask network gateway

  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$cidr" == */* ]] || die "IPv4 CIDR is required to calculate gateway: $cidr"
  [[ "$prefix" =~ ^[0-9]+$ && "$prefix" -ge 1 && "$prefix" -le 31 ]] || die "Invalid IPv4 prefix: $cidr"

  ip_int="$(ipv4_to_int "$ip")"
  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  network=$(( ip_int & mask ))
  gateway=$(( network + 1 ))

  int_to_ipv4 "$gateway"
}

fallback_ipv4_gateway() {
  local ip="$1"
  local a b c d

  IFS=. read -r a b c d <<< "$ip"
  ipv4_to_int "$ip" >/dev/null
  printf '%s.%s.%s.1' "$a" "$b" "$c"
}

strip_ipv4_prefix() {
  local value="$1"

  printf '%s' "${value%/*}"
}

validate_netplan_interface_name() {
  local interface="$1"

  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid interface name for netplan: $interface"
}

default_egress_interface() {
  local index="$1"

  if [[ -n "$EGRESS_INTERFACE" ]]; then
    printf '%s' "$EGRESS_INTERFACE"
    return 0
  fi

  case "$index" in
    1) printf 'enp0s6' ;;
    2) printf 'enp1s0' ;;
  esac
}

interface_name_from_link_index() {
  local link_index="$1"

  ip -o link show | awk -F': ' -v link_index="$link_index" '
    $1 == link_index {
      split($2, name, "@")
      print name[1]
      exit
    }
  '
}

normalize_interface_name() {
  local interface="$1"
  local resolved_interface

  validate_netplan_interface_name "$interface"

  if [[ "$interface" =~ ^[0-9]+$ ]]; then
    resolved_interface="$(interface_name_from_link_index "$interface")"
    [[ -n "$resolved_interface" ]] || die "Network interface index does not exist: $interface"
  else
    resolved_interface="$interface"
  fi

  ip link show dev "$resolved_interface" >/dev/null 2>&1 || die "Network interface does not exist: $resolved_interface"
  printf '%s' "$resolved_interface"
}

system_non_loopback_interfaces() {
  ip -o link show | awk -F': ' '
    $0 !~ /state UP/ {
      next
    }
    {
      split($2, name, "@")
      if (name[1] != "lo") {
        print name[1]
      }
    }
  '
}

load_egress_interface_options() {
  local path iface
  declare -A seen=()

  EGRESS_INTERFACE_OPTIONS=()

  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    [[ -n "${seen[$iface]-}" ]] && continue
    EGRESS_INTERFACE_OPTIONS+=("$iface")
    seen["$iface"]=1
  done < <(config_unique_bind_interfaces)

  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    iface="${path##*/}"
    [[ "$iface" != "lo" ]] || continue
    case "$iface" in
      br-* | docker* | veth* | virbr* )
        continue
        ;;
    esac
    [[ -n "${seen[$iface]-}" ]] && continue
    EGRESS_INTERFACE_OPTIONS+=("$iface")
    seen["$iface"]=1
  done
}

print_egress_interface_options() {
  local option

  load_egress_interface_options
  [[ "${#EGRESS_INTERFACE_OPTIONS[@]}" -gt 0 ]] || return 0

  echo "Available egress interfaces:"
  for option in "${!EGRESS_INTERFACE_OPTIONS[@]}"; do
    echo "  $((option + 1)). ${EGRESS_INTERFACE_OPTIONS[$option]}"
  done
}

normalize_interface_choice() {
  local value="$1"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    if ((value >= 1 && value <= ${#EGRESS_INTERFACE_OPTIONS[@]})); then
      printf '%s' "${EGRESS_INTERFACE_OPTIONS[$((value - 1))]}"
      return 0
    fi
    die "Interface number $value is not in the displayed list; enter the interface name if it is missing"
  fi

  normalize_interface_name "$value"
}

prompt_egress_interface_choice() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$label: " value
  fi

  [[ -n "$value" ]] || die "$label is required"
  printf -v "$var_name" '%s' "$(normalize_interface_choice "$value")"
}

secondary_vnic_ipv4_source() {
  local index="$1"
  local interface="$2"
  local cidr_var egress_cidr_var egress_ipv4_var
  local value

  cidr_var="SECONDARY_VNIC_${index}_IPV4_CIDR"
  egress_cidr_var="EGRESS_${index}_IPV4_CIDR"
  egress_ipv4_var="EGRESS_${index}_IPV4"
  value="${!cidr_var-}"
  [[ -n "$value" ]] || value="${!egress_cidr_var-}"
  [[ -n "$value" ]] || value="${!egress_ipv4_var-}"
  if [[ -z "$value" && "$index" == "2" ]]; then
    value="${SECONDARY_VNIC_IPV4_CIDR:-}"
  fi
  [[ -n "$value" ]] || value="$(interface_ipv4_cidr "$interface" || true)"
  printf '%s' "$value"
}

secondary_vnic_interface() {
  local index="$1"
  local secondary_var egress_var interface

  secondary_var="SECONDARY_VNIC_${index}_INTERFACE"
  egress_var="EGRESS_${index}_INTERFACE"
  interface="${!secondary_var-}"
  [[ -n "$interface" ]] || interface="${!egress_var-}"
  if [[ -z "$interface" && "$index" == "2" ]]; then
    interface="${SECONDARY_VNIC_INTERFACE:-}"
  fi
  printf '%s' "$interface"
}

secondary_vnic_gateway_override() {
  local index="$1"
  local gateway_var value

  gateway_var="SECONDARY_VNIC_${index}_GATEWAY"
  value="${!gateway_var-}"
  if [[ -z "$value" && "$index" == "2" ]]; then
    value="${SECONDARY_VNIC_GATEWAY:-}"
  fi
  printf '%s' "$value"
}

secondary_vnic_table() {
  local index="$1"
  local table_var value

  table_var="SECONDARY_VNIC_${index}_TABLE"
  value="${!table_var-}"
  [[ -n "$value" ]] || value="$((SECONDARY_VNIC_TABLE_BASE + index - 2))"
  printf '%s' "$value"
}

secondary_vnic_priority() {
  local index="$1"
  local priority_var value

  priority_var="SECONDARY_VNIC_${index}_PRIORITY"
  value="${!priority_var-}"
  [[ -n "$value" ]] || value="$((SECONDARY_VNIC_PRIORITY_BASE + index - 2))"
  printf '%s' "$value"
}

secondary_vnic_defaults() {
  local index="$1"

  if [[ "$index" == "2" ]]; then
    printf 'enp1s0'
  else
    printf 'enp%ss0' "$((index - 1))"
  fi
}

unique_secondary_egress_indexes() {
  local index iface
  declare -A seen_ifaces=()

  if [[ -n "${EGRESS_IFACES[1]-}" ]]; then
    seen_ifaces["${EGRESS_IFACES[1]}"]=1
  fi

  for ((index = 2; index <= WARP_INTERFACE_COUNT; index++)); do
    iface="${EGRESS_IFACES[$index]-}"
    [[ -n "$iface" ]] || continue
    [[ -n "${seen_ifaces[$iface]-}" ]] && continue
    seen_ifaces["$iface"]=1
    printf '%s\n' "$index"
  done
}

detected_secondary_vnic_interfaces() {
  local iface primary_iface
  declare -A seen_ifaces=()

  primary_iface="${EGRESS_IFACES[1]-}"
  [[ -n "$primary_iface" ]] && seen_ifaces["$primary_iface"]=1

  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    [[ -n "${seen_ifaces[$iface]-}" ]] && continue
    seen_ifaces["$iface"]=1
    printf '%s\n' "$iface"
  done < <(system_non_loopback_interfaces)
}

secondary_vnic_entry_yaml() {
  local index="$1"
  local selected_interface="${2:-}"
  local interface ipv4_source ipv4 gateway table priority prompt_var

  interface="$selected_interface"
  [[ -n "$interface" ]] || interface="$(secondary_vnic_interface "$index")"
  if [[ -z "$interface" ]]; then
    prompt_var="SECONDARY_VNIC_${index}_INTERFACE"
    prompt "$prompt_var" "Secondary VNIC interface $index" "$(secondary_vnic_defaults "$index")"
    interface="${!prompt_var}"
  fi
  interface="$(normalize_interface_name "$interface")"

  ipv4_source="$(secondary_vnic_ipv4_source "$index" "$interface")"
  if [[ -z "$ipv4_source" ]]; then
    prompt_var="SECONDARY_VNIC_${index}_IPV4_CIDR"
    prompt "$prompt_var" "Secondary IPv4 CIDR for $interface" "10.0.$((index - 1)).2/24"
    ipv4_source="${!prompt_var}"
  fi
  ipv4="$(strip_ipv4_prefix "$ipv4_source")"
  ipv4_to_int "$ipv4" >/dev/null

  gateway="$(secondary_vnic_gateway_override "$index")"
  if [[ -n "$gateway" ]]; then
    ipv4_to_int "$gateway" >/dev/null
  elif [[ "$ipv4_source" == */* ]]; then
    gateway="$(calculated_ipv4_gateway "$ipv4_source")"
  else
    gateway="$(fallback_ipv4_gateway "$ipv4")"
    echo "WARNING: No IPv4 prefix was available for $interface; using gateway $gateway from $ipv4/24 assumption." >&2
  fi

  table="$(secondary_vnic_table "$index")"
  priority="$(secondary_vnic_priority "$index")"
  validate_positive_integer "$table" "SECONDARY_VNIC_${index}_TABLE"
  validate_positive_integer "$priority" "SECONDARY_VNIC_${index}_PRIORITY"

  cat <<EOF
    $interface:
      dhcp4: true
      dhcp6: true
      accept-ra: true
      routes:
        - to: default
          via: $gateway
          table: $table
      routing-policy:
        - from: $ipv4/32
          table: $table
          priority: $priority
EOF

  echo "Secondary interface $index: $interface, IPv4 $ipv4, gateway $gateway, table $table, priority $priority" >&2
}

write_secondary_vnic_netplan() {
  local count index backup_path entries iface
  local -a unique_indexes detected_ifaces

  count="${SECONDARY_VNIC_COUNT:-${WARP_INTERFACE_COUNT:-2}}"
  [[ -n "$count" ]] || prompt count "How many total VNICs" "2"
  validate_positive_integer "$count" "SECONDARY_VNIC_COUNT"
  ((count >= 2)) || die "At least 2 total VNICs are required to write secondary VNIC netplan"
  validate_positive_integer "$SECONDARY_VNIC_TABLE_BASE" "SECONDARY_VNIC_TABLE_BASE"
  validate_positive_integer "$SECONDARY_VNIC_PRIORITY_BASE" "SECONDARY_VNIC_PRIORITY_BASE"

  load_egress_bindings
  mapfile -t unique_indexes < <(unique_secondary_egress_indexes)
  entries=""
  for index in "${unique_indexes[@]}"; do
    ((index <= count)) || continue
    entries+="${entries:+$'\n'}$(secondary_vnic_entry_yaml "$index")"
  done

  if [[ -z "$entries" ]]; then
    mapfile -t detected_ifaces < <(detected_secondary_vnic_interfaces)
    index=2
    for iface in "${detected_ifaces[@]}"; do
      ((index <= count)) || break
      entries+="${entries:+$'\n'}$(secondary_vnic_entry_yaml "$index" "$iface")"
      ((index++))
    done
  fi

  if [[ -z "$entries" ]]; then
    echo "No unique secondary VNIC interfaces found; no secondary netplan was written."
    echo "Set SECONDARY_VNIC_2_INTERFACE=enp1s0 if the secondary NIC is not detectable with ip link."
    return 0
  fi

  if [[ -f "$SECONDARY_NETPLAN_PATH" ]]; then
    backup_path="$SECONDARY_NETPLAN_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$SECONDARY_NETPLAN_PATH" "$backup_path"
    chmod 600 "$backup_path"
    echo "Backed up old secondary netplan to $backup_path"
  fi

  umask 077
  cat > "$SECONDARY_NETPLAN_PATH" <<EOF
network:
  version: 2
  ethernets:
$entries
EOF

  chmod 600 "$SECONDARY_NETPLAN_PATH"
  echo "Wrote secondary VNIC netplan to $SECONDARY_NETPLAN_PATH"
}

load_egress_bindings() {
  local index iface_var v4_var v6_var iface v4_addr v6_addr previous_iface

  for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
    iface_var="EGRESS_${index}_INTERFACE"
    v4_var="EGRESS_${index}_IPV4"
    v6_var="EGRESS_${index}_IPV6"

    iface="${!iface_var-}"
    [[ -n "$iface" ]] || iface="$(config_bind_interface "$(warp_profile_tag 4 "$index")")"
    [[ -n "$iface" ]] || iface="$(default_egress_interface "$index")"
    if [[ -z "$iface" && "$index" -gt 1 ]]; then
      previous_iface="EGRESS_$((index - 1))_INTERFACE"
      iface="${!previous_iface-}"
    fi
    [[ -n "$iface" ]] || die "$iface_var is required"
    iface="$(normalize_interface_name "$iface")"
    printf -v "$iface_var" '%s' "$iface"

    v4_addr="${!v4_var-}"
    [[ -n "$v4_addr" ]] || v4_addr="$(interface_address 4 "$iface")"
    [[ -n "$v4_addr" ]] || die "Could not detect IPv4 address for $iface; set $v4_var"

    v6_addr="${!v6_var-}"
    [[ -n "$v6_addr" ]] || v6_addr="$(interface_address 6 "$iface")"
    [[ -n "$v6_addr" ]] || die "Could not detect IPv6 address for $iface; set $v6_var"

    EGRESS_IFACES[$index]="$iface"
    EGRESS_V4_ADDRS[$index]="$v4_addr"
    EGRESS_V6_ADDRS[$index]="$v6_addr"
  done
}

configure_egress_interfaces() {
  local force="${1:-false}"
  local index iface_var previous_iface_var default_value

  print_egress_interface_options
  for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
    iface_var="EGRESS_${index}_INTERFACE"
    if [[ "$force" != "true" && -n "${!iface_var-}" ]]; then
      printf -v "$iface_var" '%s' "$(normalize_interface_name "${!iface_var}")"
      continue
    fi

    default_value="${!iface_var-}"
    [[ -n "$default_value" ]] || default_value="$(config_bind_interface "$(warp_profile_tag 4 "$index")")"
    [[ -n "$default_value" ]] || default_value="$(default_egress_interface "$index")"
    if [[ -z "$default_value" && "$index" -gt 1 ]]; then
      previous_iface_var="EGRESS_$((index - 1))_INTERFACE"
      default_value="${!previous_iface_var-}"
    fi
    if [[ "$force" != "true" && -n "$default_value" ]]; then
      printf -v "$iface_var" '%s' "$(normalize_interface_name "$default_value")"
      continue
    fi
    if [[ -n "$default_value" ]]; then
      prompt_egress_interface_choice "$iface_var" "Egress interface number/name for WARP slot $index (repeat allowed)" "$default_value"
    else
      prompt_egress_interface_choice "$iface_var" "Egress interface number/name for WARP slot $index (repeat allowed)"
    fi
  done
}

configure_generated_egress_interfaces() {
  local interface_count="$1"
  local profiles_per_interface="$2"
  local old_slot_count="${WARP_INTERFACE_COUNT:-0}"
  local interface_index profile_index slot iface_var default_var default_value
  local -a existing_ifaces selected_ifaces

  mapfile -t existing_ifaces < <(config_unique_bind_interfaces)
  print_egress_interface_options

  for ((slot = 1; slot <= old_slot_count; slot++)); do
    iface_var="EGRESS_${slot}_INTERFACE"
    unset "$iface_var"
  done

  for ((interface_index = 1; interface_index <= interface_count; interface_index++)); do
    default_var="EGRESS_${interface_index}_INTERFACE"
    default_value="${!default_var-}"
    [[ -n "$default_value" ]] || default_value="${existing_ifaces[$((interface_index - 1))]-}"
    [[ -n "$default_value" ]] || default_value="${EGRESS_INTERFACE_OPTIONS[$((interface_index - 1))]-}"

    iface_var="SELECTED_EGRESS_${interface_index}_INTERFACE"
    if [[ -n "$default_value" ]]; then
      prompt_egress_interface_choice "$iface_var" "Egress interface $interface_index number/name" "$default_value"
    else
      prompt_egress_interface_choice "$iface_var" "Egress interface $interface_index number/name"
    fi
    selected_ifaces[$interface_index]="${!iface_var}"
  done

  WARP_INTERFACE_COUNT=$((interface_count * profiles_per_interface))

  for ((interface_index = 1; interface_index <= interface_count; interface_index++)); do
    for ((profile_index = 1; profile_index <= profiles_per_interface; profile_index++)); do
      slot=$(((interface_index - 1) * profiles_per_interface + profile_index))
      iface_var="EGRESS_${slot}_INTERFACE"
      printf -v "$iface_var" '%s' "${selected_ifaces[$interface_index]}"
    done
  done

  echo "Generating $profiles_per_interface IPv4 WARP and $profiles_per_interface IPv6 WARP per egress interface."
  echo "Total internal WARP slots: $WARP_INTERFACE_COUNT"
}

prompt_keep_existing() {
  local var_name="$1"
  local label="$2"
  local existing_value="$3"
  local secret="${4:-false}"
  local value

  if [[ -n "$existing_value" ]]; then
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$label [press Enter to keep existing]: " value
      echo
    else
      read -r -p "$label [$existing_value]: " value
    fi
    value="${value:-$existing_value}"
  else
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$label: " value
      echo
    else
      read -r -p "$label: " value
    fi
    [[ -n "$value" ]] || die "$label is required because no existing value was found in $CONFIG_PATH"
  fi

  printf -v "$var_name" '%s' "$value"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

rand_password() {
  openssl rand -base64 24
}

existing_or_rand_password() {
  local existing_value="$1"

  if [[ -n "$existing_value" ]]; then
    printf '%s' "$existing_value"
  else
    rand_password
  fi
}

github_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l | armv7) printf 'armv7' ;;
    i386 | i686) printf '386' ;;
    *) die "Unsupported architecture for auto-download: $(uname -m)" ;;
  esac
}

warp_yg_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l | armv7) printf 'arm' ;;
    i386 | i686) printf '386' ;;
    *) die "Unsupported architecture for warp-yg fallback: $(uname -m)" ;;
  esac
}

github_latest_asset_url() {
  local repo="$1"
  local asset_regex="$2"
  local api_url="https://api.github.com/repos/$repo/releases/latest"

  fetch_url "$api_url" | awk -v re="$asset_regex" '
    /"browser_download_url"[[:space:]]*:/ {
      line = $0
      sub(/.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      if (line ~ re && line !~ /(sha256|checksums|\.sha|\.sig|\.asc)$/) {
        print line
        exit
      }
    }
  '
}

first_executable() {
  local dir="$1"
  local name="$2"
  local path

  path="$(find "$dir" -type f -name "$name" -perm /111 2>/dev/null | head -n 1)"
  [[ -n "$path" ]] || path="$(find "$dir" -type f -name "$name" 2>/dev/null | head -n 1)"
  printf '%s' "$path"
}

install_github_binary() {
  local repo="$1"
  local name="$2"
  local dest="$3"
  local asset_regex="$4"
  local url archive tmp extract_dir binary

  [[ -x "$dest" ]] && return 0

  need_fetch_cmd
  need_cmd find
  need_cmd head
  need_cmd mktemp

  url="$(github_latest_asset_url "$repo" "$asset_regex")"
  [[ -n "$url" ]] || die "Could not find release asset for $repo matching $asset_regex"

  tmp="$(mktemp -d)"
  archive="$tmp/$(basename "$url")"
  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir" "$(dirname "$dest")"

  echo "Downloading $name from $url..."
  fetch_url "$url" "$archive"

  case "$archive" in
    *.tar.gz | *.tgz)
      need_cmd tar
      tar -xzf "$archive" -C "$extract_dir"
      binary="$(first_executable "$extract_dir" "$name")"
      [[ -n "$binary" ]] || die "Could not find $name inside $archive"
      cp "$binary" "$dest"
      ;;
    *.gz)
      need_cmd gzip
      gzip -dc "$archive" > "$dest"
      ;;
    *.zip)
      need_cmd unzip
      unzip -q "$archive" -d "$extract_dir"
      binary="$(first_executable "$extract_dir" "$name")"
      [[ -n "$binary" ]] || die "Could not find $name inside $archive"
      cp "$binary" "$dest"
      ;;
    *)
      cp "$archive" "$dest"
      ;;
  esac

  chmod 0755 "$dest"
  rm -rf "$tmp"
  echo "Installed $name to $dest"
}

ensure_warp_yg_repo() {
  [[ "$AUTO_DOWNLOAD_WARP_TOOLS" == "true" ]] || return 0

  need_cmd git
  mkdir -p "$(dirname "$WARP_YG_REPO_DIR")"

  if [[ -d "$WARP_YG_REPO_DIR/.git" ]]; then
    git -C "$WARP_YG_REPO_DIR" pull --ff-only || echo "WARNING: could not update $WARP_YG_REPO_DIR; using existing checkout"
  elif [[ -e "$WARP_YG_REPO_DIR" ]]; then
    die "$WARP_YG_REPO_DIR exists but is not a git checkout"
  else
    git clone --depth 1 "$WARP_YG_REPO_URL" "$WARP_YG_REPO_DIR"
  fi
}

ensure_warp_tools() {
  local arch linux_arch warp_go_regex wgcf_regex

  [[ "$AUTO_DOWNLOAD_WARP_TOOLS" == "true" ]] || return 0

  arch="$(github_arch)"
  linux_arch="linux.*$arch"
  warp_go_regex="[Ll]inux.*$arch"
  wgcf_regex="$linux_arch"

  case "$WARP_TOOL" in
    auto)
      install_github_binary "Fangliding/warp-go" "warp-go" "$WARP_GO_BIN" "$warp_go_regex"
      install_github_binary "ViRb3/wgcf" "wgcf" "$WGCF_BIN" "$wgcf_regex"
      ;;
    warp-yg)
      install_github_binary "Fangliding/warp-go" "warp-go" "$WARP_GO_BIN" "$warp_go_regex"
      ;;
    warp-go)
      install_github_binary "Fangliding/warp-go" "warp-go" "$WARP_GO_BIN" "$warp_go_regex"
      ;;
    wgcf)
      install_github_binary "ViRb3/wgcf" "wgcf" "$WGCF_BIN" "$wgcf_regex"
      ;;
  esac
}

write_warp_yg_fallback_conf() {
  local output_path="$1"
  local cpu warpapi output private_key device_id warp_token

  need_cmd mktemp
  cpu="$(warp_yg_arch)"
  warpapi="$(mktemp)"

  fetch_url "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/point/cpu1/$cpu" "$warpapi"
  chmod +x "$warpapi"
  output="$("$warpapi")"
  rm -f "$warpapi"

  private_key="$(awk -F ': ' '/private_key/{print $2}' <<< "$output")"
  device_id="$(awk -F ': ' '/device_id/{print $2}' <<< "$output")"
  warp_token="$(awk -F ': ' '/token/{print $2}' <<< "$output")"
  [[ -n "$private_key" && -n "$device_id" && -n "$warp_token" ]] || die "warp-yg fallback did not return a complete WARP account"

  cat > "$output_path" <<EOF
[Account]
Device = $device_id
PrivateKey = $private_key
Token = $warp_token
Type = free
Name = WARP
MTU  = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 162.159.193.10:2408
# AllowedIPs = 0.0.0.0/0
# AllowedIPs = ::/0
KeepAlive = 30
EOF
}

valid_warp_yg_conf() {
  local path="$1"

  [[ -s "$path" ]] || return 1
  grep -q '^[[:space:]]*PrivateKey[[:space:]]*=' "$path" || return 1
  grep -q '^[[:space:]]*Token[[:space:]]*=' "$path" || return 1
  grep -q '^[[:space:]]*PublicKey[[:space:]]*=' "$path" || return 1
}

write_warp_yg_conf() {
  local output_path="$1"

  need_fetch_cmd

  case "$WARP_YG_ACCOUNT_SOURCE" in
    auto | zeroteam | warpapi) ;;
    *) die "Unsupported WARP_YG_ACCOUNT_SOURCE: $WARP_YG_ACCOUNT_SOURCE" ;;
  esac

  if [[ "$WARP_YG_ACCOUNT_SOURCE" == "warpapi" || -f "$WARP_YG_FAIL_MARKER" ]]; then
    write_warp_yg_fallback_conf "$output_path"
    return 0
  fi

  if fetch_url "https://api.zeroteam.top/warp?format=warp-go" "$output_path" && valid_warp_yg_conf "$output_path"; then
    return 0
  fi

  rm -f "$output_path"
  touch "$WARP_YG_FAIL_MARKER"

  if [[ "$WARP_YG_ACCOUNT_SOURCE" == "zeroteam" ]]; then
    die "warp-yg zeroteam account API failed"
  fi

  echo "WARNING: zeroteam WARP API failed; using warp-yg fallback generator for the rest of this run" >&2
  write_warp_yg_fallback_conf "$output_path"
}

profile_value() {
  local profile="$1"
  local key="$2"
  awk -v k="$key" '
    index($0, "=") {
      left = substr($0, 1, index($0, "=") - 1)
      right = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == k) {
        gsub(/^[[:space:]]+|[[:space:]\r]+$/, "", right)
        print right
        exit
      }
    }
  ' "$profile"
}

profile_address_v4() {
  local profile="$1"
  awk '
    index($0, "=") {
      left = substr($0, 1, index($0, "=") - 1)
      right = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == "Address") {
        n = split(right, values, ",")
        for (i = 1; i <= n; i++) {
          value = values[i]
          gsub(/^[[:space:]]+|[[:space:]\r]+$/, "", value)
          if (value ~ /^[0-9.]+\/[0-9]+$/) {
            print value
            exit
          }
        }
      }
    }
  ' "$profile"
}

profile_address_v6() {
  local profile="$1"
  awk '
    index($0, "=") {
      left = substr($0, 1, index($0, "=") - 1)
      right = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
      if (left == "Address") {
        n = split(right, values, ",")
        for (i = 1; i <= n; i++) {
          value = values[i]
          gsub(/^[[:space:]]+|[[:space:]\r]+$/, "", value)
          if (value ~ /:/) {
            print value
            exit
          }
        }
      }
    }
  ' "$profile"
}

profile_endpoint_host() {
  local profile="$1"
  local endpoint

  endpoint="$(profile_value "$profile" "Endpoint")"
  [[ -n "$endpoint" ]] || return 0

  if [[ "$endpoint" =~ ^\[([0-9a-fA-F:.]+)\]:[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$endpoint" =~ ^([^:]+):[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

profile_endpoint_port() {
  local profile="$1"
  local endpoint

  endpoint="$(profile_value "$profile" "Endpoint")"
  [[ -n "$endpoint" ]] || return 0

  if [[ "$endpoint" =~ \]:([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$endpoint" =~ :([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

json_reserved() {
  local profile="$1"

  awk '
    /"reserved"[[:space:]]*:/ {
      line = $0
      if (line ~ /\[/) {
        while (line !~ /\]/ && getline next_line) {
          line = line " " next_line
        }
        sub(/.*"reserved"[[:space:]]*:[[:space:]]*\[/, "", line)
        sub(/\].*/, "", line)
        gsub(/[[:space:]]+/, "", line)
        if (line != "") {
          print "[" line "]"
        }
        exit
      }
      if (line ~ /"reserved"[[:space:]]*:[[:space:]]*"/) {
        sub(/.*"reserved"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        if (line != "") {
          print "\"" line "\""
        }
        exit
      }
    }
  ' "$profile"
}

detect_warp_tool() {
  case "$WARP_TOOL" in
    auto)
      if [[ -x "$WARP_GO_BIN" ]]; then
        WARP_TOOL="warp-yg"
      elif [[ -x "$WGCF_BIN" ]]; then
        WARP_TOOL="wgcf"
      else
        die "Missing WARP generator: set WARP_GO_BIN or WGCF_BIN to an executable"
      fi
      ;;
    warp-yg)
      [[ -x "$WARP_GO_BIN" ]] || die "warp-go binary not found or not executable at $WARP_GO_BIN"
      ;;
    warp-go)
      [[ -x "$WARP_GO_BIN" ]] || die "warp-go binary not found or not executable at $WARP_GO_BIN"
      ;;
    wgcf)
      [[ -x "$WGCF_BIN" ]] || die "wgcf binary not found or not executable at $WGCF_BIN"
      ;;
    *)
      die "Unsupported WARP_TOOL: $WARP_TOOL"
      ;;
  esac
}

report_warp_generator_status() {
  case "$CURRENT_WARP_FLAVOR" in
    warp-yg | warp-go)
      if [[ -x "$WARP_GO_BIN" ]]; then
        echo "WARP generator ready: warp-go at $WARP_GO_BIN"
      elif [[ "$AUTO_DOWNLOAD_WARP_TOOLS" == "true" ]]; then
        echo "WARNING: warp-go is not available at $WARP_GO_BIN; it will be downloaded before WARP generation."
      else
        echo "WARNING: warp-go is not available at $WARP_GO_BIN. Set WARP_GO_BIN or enable AUTO_DOWNLOAD_WARP_TOOLS before regenerating WARP."
      fi
      ;;
    wgcf)
      if [[ -x "$WGCF_BIN" ]]; then
        echo "WARP generator ready: wgcf at $WGCF_BIN"
      elif [[ "$AUTO_DOWNLOAD_WARP_TOOLS" == "true" ]]; then
        echo "WARNING: wgcf is not available at $WGCF_BIN; it will be downloaded before WARP generation."
      else
        echo "WARNING: wgcf is not available at $WGCF_BIN. Set WGCF_BIN or enable AUTO_DOWNLOAD_WARP_TOOLS before regenerating WARP."
      fi
      ;;
  esac
}

make_warp_profile() {
  local tag="$1"
  local dir profile singbox_profile

  if [[ "$WARP_TOOL" == "warp-yg" ]]; then
    dir="$WARP_YG_BASE/$tag"
    profile="$dir/warp-yg-profile.conf"
    singbox_profile="$dir/warp-yg-singbox.json"

    mkdir -p "$dir"
    cp "$WARP_GO_BIN" "$dir/warp-go"
    chmod +x "$dir/warp-go"

    if [[ ! -s "$dir/warp.conf" ]]; then
      write_warp_yg_conf "$dir/warp.conf"
    fi

    (
      cd "$dir"
      ./warp-go --config=warp.conf --export-wireguard="$profile"
      ./warp-go --config=warp.conf --export-singbox="$singbox_profile"
    )

    [[ -f "$profile" ]] || die "WARP profile was not generated: $profile"
    [[ -f "$singbox_profile" ]] || die "WARP sing-box profile was not generated: $singbox_profile"
  elif [[ "$WARP_TOOL" == "warp-go" ]]; then
    dir="$WARP_GO_BASE/$tag"
    profile="$dir/warp-go-profile.conf"
    singbox_profile="$dir/warp-go-singbox.json"

    mkdir -p "$dir"
    cp "$WARP_GO_BIN" "$dir/warp-go"
    chmod +x "$dir/warp-go"

    (
      cd "$dir"
      if [[ ! -f warp.conf ]]; then
        ./warp-go --register
      fi
      ./warp-go --config=warp.conf --export-wireguard="$profile"
      ./warp-go --config=warp.conf --export-singbox="$singbox_profile"
    )

    [[ -f "$profile" ]] || die "WARP profile was not generated: $profile"
    [[ -f "$singbox_profile" ]] || die "WARP sing-box profile was not generated: $singbox_profile"
  else
    dir="$WGCF_BASE/$tag"
    profile="$dir/wgcf-profile.conf"

    mkdir -p "$dir"
    cp "$WGCF_BIN" "$dir/wgcf"
    chmod +x "$dir/wgcf"

    (
      cd "$dir"
      if [[ ! -f wgcf-account.toml ]]; then
        ./wgcf register --accept-tos
      fi
      ./wgcf generate
    )

    [[ -f "$profile" ]] || die "WARP profile was not generated: $profile"
    singbox_profile=""
  fi
}

config_acme_domain() {
  local index="$1"

  [[ -f "$CONFIG_PATH" ]] || return 0
  awk -v target="$index" '
    /"domain"[[:space:]]*:[[:space:]]*\[/ {
      in_domain = 1
      count = 0
      next
    }
    in_domain && /"/ {
      line = $0
      sub(/^[[:space:]]*"/, "", line)
      sub(/".*/, "", line)
      if (line != "") {
        count++
        if (count == target) {
          print line
          exit
        }
      }
    }
    in_domain && /\]/ {
      in_domain = 0
    }
  ' "$CONFIG_PATH"
}

require_base_commands() {
  need_cmd awk
  need_cmd cp
  need_cmd grep
  need_cmd ip
  need_cmd mkdir
  need_cmd mktemp
  need_cmd openssl
  need_cmd sing-box
  need_cmd systemctl
  need_cmd tr
}

init_runtime() {
  WARP_YG_FAIL_MARKER="$(mktemp /tmp/warp-yg-zeroteam.XXXXXX)"
  rm -f "$WARP_YG_FAIL_MARKER"
  trap 'rm -f "$WARP_YG_FAIL_MARKER"' EXIT
}

load_passwords_from_config() {
  local family kind index user_name existing legacy

  for family in 4 6; do
    for kind in direct warp; do
      for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
        user_name="${kind}-v${family}-${index}"
        existing="$(config_user_password "$user_name")"
        if [[ -z "$existing" ]]; then
          legacy="$(legacy_user_name "$user_name")"
          [[ -z "$legacy" ]] || existing="$(config_user_password "$legacy")"
        fi
        USER_PASSWORDS[$user_name]="$(existing_or_rand_password "$existing")"
      done
    done
  done
}

regenerate_passwords() {
  local family kind index user_name

  for family in 4 6; do
    for kind in direct warp; do
      for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
        user_name="${kind}-v${family}-${index}"
        USER_PASSWORDS[$user_name]="$(rand_password)"
      done
    done
  done
}

detect_existing_warp_flavor() {
  if [[ -f "$WARP_YG_BASE/warp-ipv4-1/warp-yg-profile.conf" && -f "$WARP_YG_BASE/warp-ipv6-1/warp-yg-profile.conf" ]]; then
    printf 'warp-yg'
  elif [[ -f "$WARP_GO_BASE/warp-ipv4-1/warp-go-profile.conf" && -f "$WARP_GO_BASE/warp-ipv6-1/warp-go-profile.conf" ]]; then
    printf 'warp-go'
  elif [[ -f "$WGCF_BASE/warp-ipv4-1/wgcf-profile.conf" && -f "$WGCF_BASE/warp-ipv6-1/wgcf-profile.conf" ]]; then
    printf 'wgcf'
  else
    printf '%s' "$WARP_TOOL"
  fi
}

warp_profile_path_for() {
  local flavor="$1"
  local tag="$2"

  case "$flavor" in
    warp-yg) printf '%s/%s/warp-yg-profile.conf' "$WARP_YG_BASE" "$tag" ;;
    warp-go) printf '%s/%s/warp-go-profile.conf' "$WARP_GO_BASE" "$tag" ;;
    wgcf) printf '%s/%s/wgcf-profile.conf' "$WGCF_BASE" "$tag" ;;
    *) die "Unsupported WARP flavor: $flavor" ;;
  esac
}

warp_singbox_path_for() {
  local flavor="$1"
  local tag="$2"

  case "$flavor" in
    warp-yg) printf '%s/%s/warp-yg-singbox.json' "$WARP_YG_BASE" "$tag" ;;
    warp-go) printf '%s/%s/warp-go-singbox.json' "$WARP_GO_BASE" "$tag" ;;
    wgcf) printf '' ;;
    *) die "Unsupported WARP flavor: $flavor" ;;
  esac
}

set_warp_profile_paths() {
  local flavor="$1"
  local family index key tag

  case "$flavor" in
    warp-yg | warp-go | wgcf) ;;
    *)
      die "Unsupported WARP flavor: $flavor"
      ;;
  esac

  WARP_PROFILE_PATHS=()
  WARP_SINGBOX_PATHS=()

  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      key="${family}:${index}"
      tag="$(warp_profile_tag "$family" "$index")"
      WARP_PROFILE_PATHS[$key]="$(warp_profile_path_for "$flavor" "$tag")"
      WARP_SINGBOX_PATHS[$key]="$(warp_singbox_path_for "$flavor" "$tag")"
    done
  done
}

load_warp_profile_state() {
  local flavor="${1:-$CURRENT_WARP_FLAVOR}"
  local family index key profile singbox reserved value

  set_warp_profile_paths "$flavor"

  WARP_KEYS=()
  WARP_ADDRS=()
  WARP_PEERS=()
  WARP_ENDPOINTS=()
  WARP_PORTS=()
  WARP_RESERVED=()

  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      key="${family}:${index}"
      profile="${WARP_PROFILE_PATHS[$key]}"
      [[ -f "$profile" ]] || return 1

      WARP_KEYS[$key]="$(profile_value "$profile" "PrivateKey")"
      if [[ "$family" == "4" ]]; then
        WARP_ADDRS[$key]="$(profile_address_v4 "$profile")"
      else
        WARP_ADDRS[$key]="$(profile_address_v6 "$profile")"
      fi
      WARP_PEERS[$key]="$(profile_value "$profile" "PublicKey")"
      WARP_ENDPOINTS[$key]="$(profile_endpoint_host "$profile")"
      WARP_PORTS[$key]="$(profile_endpoint_port "$profile")"
      WARP_RESERVED[$key]="[0, 0, 0]"

      if [[ "$flavor" == "warp-yg" || "$flavor" == "warp-go" ]]; then
        singbox="${WARP_SINGBOX_PATHS[$key]}"
        [[ -f "$singbox" ]] || return 1
        reserved="$(json_reserved "$singbox")"
        [[ -n "$reserved" ]] || reserved="[0, 0, 0]"
        WARP_RESERVED[$key]="$reserved"
      fi

      for value in "${WARP_KEYS[$key]}" "${WARP_ADDRS[$key]}" "${WARP_PEERS[$key]}"; do
        [[ -n "$value" ]] || return 1
      done
    done
  done
}

all_warp_tags() {
  local family index

  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      warp_profile_tag "$family" "$index"
      echo
    done
  done
}

missing_warp_tags() {
  local family index key tag profile singbox

  set_warp_profile_paths "$CURRENT_WARP_FLAVOR"
  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      key="${family}:${index}"
      tag="$(warp_profile_tag "$family" "$index")"
      profile="${WARP_PROFILE_PATHS[$key]}"
      singbox="${WARP_SINGBOX_PATHS[$key]}"

      if [[ ! -f "$profile" ]]; then
        printf '%s\n' "$tag"
      elif [[ "$CURRENT_WARP_FLAVOR" != "wgcf" && ! -f "$singbox" ]]; then
        printf '%s\n' "$tag"
      fi
    done
  done
}

ensure_warp_profile_state() {
  local -a tags

  if load_warp_profile_state "$CURRENT_WARP_FLAVOR"; then
    return 0
  fi

  mapfile -t tags < <(missing_warp_tags)
  if ((${#tags[@]} > 0)); then
    echo "Missing WARP profiles for ${#tags[@]} profile(s); generating them now..."
    regenerate_warp_tags "${tags[@]}"
    load_warp_profile_state "$CURRENT_WARP_FLAVOR" || die "Failed to load generated WARP profiles"
    return 0
  fi

  die "Generated WARP profiles are incomplete; choose menu option 2 to regenerate all WARP profiles"
}

clear_warp_profile() {
  local tag="$1"

  case "$CURRENT_WARP_FLAVOR" in
    warp-yg)
      rm -f "$WARP_YG_BASE/$tag/warp.conf" "$WARP_YG_BASE/$tag/warp-yg-profile.conf" "$WARP_YG_BASE/$tag/warp-yg-singbox.json"
      ;;
    warp-go)
      rm -f "$WARP_GO_BASE/$tag/warp.conf" "$WARP_GO_BASE/$tag/warp-go-profile.conf" "$WARP_GO_BASE/$tag/warp-go-singbox.json"
      ;;
    wgcf)
      rm -f "$WGCF_BASE/$tag/wgcf-account.toml" "$WGCF_BASE/$tag/wgcf-profile.conf"
      ;;
  esac
}

prepare_warp_generation() {
  WARP_TOOL="$CURRENT_WARP_FLAVOR"
  ensure_warp_tools
  detect_warp_tool
  CURRENT_WARP_FLAVOR="$WARP_TOOL"

  if [[ "$CURRENT_WARP_FLAVOR" == "warp-yg" ]]; then
    ensure_warp_yg_repo
  fi
}

regenerate_warp_tags() {
  local tag

  prepare_warp_generation
  for tag in "$@"; do
    echo "Regenerating $tag with $CURRENT_WARP_FLAVOR..."
    clear_warp_profile "$tag"
    make_warp_profile "$tag"
  done
}

render_warp_endpoint() {
  local family="$1"
  local index="$2"
  local map_key tag allowed_ips resolver bind_address bind_key endpoint port

  map_key="${family}:${index}"
  tag="warp-v${family}-${index}"
  endpoint="${WARP_ENDPOINTS[$map_key]:-engage.cloudflareclient.com}"
  port="${WARP_PORTS[$map_key]:-2408}"

  if [[ "$family" == "4" ]]; then
    allowed_ips="0.0.0.0/0"
    resolver="ipv4_only"
    bind_key="inet4_bind_address"
    bind_address="${EGRESS_V4_ADDRS[$index]}"
  else
    allowed_ips="::/0"
    resolver="ipv6_only"
    bind_key="inet6_bind_address"
    bind_address="${EGRESS_V6_ADDRS[$index]}"
  fi

  cat <<EOF
    {
      "type": "wireguard",
      "tag": "$tag",
      "mtu": 1280,
      "address": [
        "${WARP_ADDRS[$map_key]}"
      ],
      "private_key": "${WARP_KEYS[$map_key]}",
      "peers": [
        {
          "address": "$endpoint",
          "port": $port,
          "public_key": "${WARP_PEERS[$map_key]}",
          "reserved": ${WARP_RESERVED[$map_key]},
          "allowed_ips": [
            "$allowed_ips"
          ]
        }
      ],
      "bind_interface": "${EGRESS_IFACES[$index]}",
      "$bind_key": "$bind_address",
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "$resolver"
      }
    }
EOF
}

render_warp_endpoints() {
  local family index first

  first=true
  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      if [[ "$first" == "true" ]]; then
        first=false
      else
        echo ","
      fi
      render_warp_endpoint "$family" "$index"
    done
  done
}

render_hysteria_users() {
  local family kind index user_name password first

  first=true
  for family in 4 6; do
    for kind in direct warp; do
      for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
        user_name="${kind}-v${family}-${index}"
        password="$(json_escape "$(user_password "$user_name")")"
        if [[ "$first" == "true" ]]; then
          first=false
        else
          echo ","
        fi
        cat <<EOF
        {
          "name": "$user_name",
          "password": "$password"
        }
EOF
      done
    done
  done
}

render_direct_outbounds() {
  local family index tag resolver bind_key bind_address first

  first=true
  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      tag="direct-v${family}-${index}"
      if [[ "$family" == "4" ]]; then
        resolver="ipv4_only"
        bind_key="inet4_bind_address"
        bind_address="${EGRESS_V4_ADDRS[$index]}"
      else
        resolver="ipv6_only"
        bind_key="inet6_bind_address"
        bind_address="${EGRESS_V6_ADDRS[$index]}"
      fi

      if [[ "$first" == "true" ]]; then
        first=false
      else
        echo ","
      fi
      cat <<EOF
    {
      "type": "direct",
      "tag": "$tag",
      "bind_interface": "${EGRESS_IFACES[$index]}",
      "$bind_key": "$bind_address",
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "$resolver"
      }
    }
EOF
    done
  done
}

render_auth_user_array() {
  local family kind index user_name first

  family="$1"
  first=true
  for kind in direct warp; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      user_name="${kind}-v${family}-${index}"
      if [[ "$first" == "true" ]]; then
        first=false
      else
        echo ","
      fi
      printf '          "%s"' "$user_name"
    done
  done
  echo
}

render_user_outbound_rules() {
  local family kind index user_name first

  first=true
  for family in 4 6; do
    for kind in direct warp; do
      for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
        user_name="${kind}-v${family}-${index}"
        if [[ "$first" == "true" ]]; then
          first=false
        else
          echo ","
        fi
        cat <<EOF
      {
        "auth_user": "$user_name",
        "outbound": "$user_name"
      }
EOF
      done
    done
  done
}

render_route_rules() {
  cat <<EOF
      {
        "auth_user": [
$(render_auth_user_array 4)
        ],
        "action": "resolve",
        "strategy": "ipv4_only"
      },
      {
        "auth_user": [
$(render_auth_user_array 6)
        ],
        "action": "resolve",
        "strategy": "ipv6_only"
      },
      {
        "auth_user": [
$(render_auth_user_array 4)
        ],
        "ip_version": 6,
        "action": "reject"
      },
      {
        "auth_user": [
$(render_auth_user_array 6)
        ],
        "ip_version": 4,
        "action": "reject"
      },
$(render_user_outbound_rules)
EOF
}

write_singbox_config() {
  local domain_v4_json domain_v6_json acme_email_json cf_token_json backup_path
  local endpoints_json users_json outbounds_json route_rules_json

  ensure_warp_profile_state
  load_egress_bindings

  domain_v4_json="$(json_escape "$DOMAIN_V4")"
  domain_v6_json="$(json_escape "$DOMAIN_V6")"
  acme_email_json="$(json_escape "$ACME_EMAIL")"
  cf_token_json="$(json_escape "$CF_TOKEN")"
  endpoints_json="$(render_warp_endpoints)"
  users_json="$(render_hysteria_users)"
  outbounds_json="$(render_direct_outbounds)"
  route_rules_json="$(render_route_rules)"

  if [[ -f "$CONFIG_PATH" ]]; then
    backup_path="$CONFIG_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$backup_path"
    chmod 600 "$backup_path"
    echo "Backed up old config to $backup_path"
  fi

  umask 077
  cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "cf-dns",
        "server": "1.1.1.1"
      }
    ]
  },
  "endpoints": [
$endpoints_json
  ],
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [
$users_json
      ],
      "tls": {
        "enabled": true,
        "server_name": "$domain_v4_json",
        "acme": {
          "domain": [
            "$domain_v4_json",
            "$domain_v6_json"
          ],
          "email": "$acme_email_json",
          "dns01_challenge": {
            "provider": "cloudflare",
            "api_token": "$cf_token_json"
          }
        }
      }
    }
  ],
  "outbounds": [
$outbounds_json
  ],
  "route": {
    "rules": [
$route_rules_json
    ],
    "final": "direct-v4-1"
  }
}
EOF

  chmod 600 "$CONFIG_PATH"

  echo "Checking sing-box config..."
  sing-box check -c "$CONFIG_PATH"

  echo "Restarting sing-box..."
  systemctl enable --now sing-box
  systemctl restart sing-box
}

print_proxy_information() {
  local country node_name node_name_v6 server sni_name server_index family kind index user_name password display_index

  prompt country "Country"
  prompt node_name "Node name"
  node_name_v6="${node_name}-v6"

  echo
  echo "Proxy information:"
  for server_index in 1 2; do
    if [[ "$server_index" == "1" ]]; then
      server="$DOMAIN_V4"
      sni_name="$node_name"
    else
      server="$DOMAIN_V6"
      sni_name="$node_name_v6"
    fi
    for family in 4 6; do
      for kind in direct warp; do
        for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
          user_name="${kind}-v${family}-${index}"
          password="$(user_password "$user_name")"
          printf -v display_index '%02d' "$index"
          echo "{ name: \"oracle $country $sni_name ${kind}-v${family} $display_index\", type: hysteria2, server: $server, port: $LISTEN_PORT, password: \"$password\", sni: \"$server\", skip-cert-verify: false }"
        done
      done
    done
  done
  echo
}

regenerate_all_warp_profiles() {
  local -a tags

  mapfile -t tags < <(all_warp_tags)
  regenerate_warp_tags "${tags[@]}"
}

prepare_new_config_inputs() {
  local existing_interface_count default_domain_v4 default_domain_v6
  local default_egress_interface_count default_profiles_per_interface
  local -a existing_ifaces

  existing_interface_count="$(config_interface_count)"
  mapfile -t existing_ifaces < <(config_unique_bind_interfaces)
  default_domain_v4="${DOMAIN_V4:-xxx.com}"
  default_domain_v6="${DOMAIN_V6:-xxx-v6.com}"
  default_egress_interface_count="${EGRESS_INTERFACE_COUNT:-${#existing_ifaces[@]}}"
  if [[ ! "$default_egress_interface_count" =~ ^[1-9][0-9]*$ ]]; then
    default_egress_interface_count="2"
  fi
  default_profiles_per_interface="${WARP_PROFILES_PER_INTERFACE:-}"
  if [[ -z "$default_profiles_per_interface" && -n "$existing_interface_count" && "${#existing_ifaces[@]}" -gt 0 ]]; then
    default_profiles_per_interface="$((existing_interface_count / ${#existing_ifaces[@]}))"
    [[ "$default_profiles_per_interface" -gt 0 ]] || default_profiles_per_interface="1"
  fi
  [[ -n "$default_profiles_per_interface" ]] || default_profiles_per_interface="1"

  prompt DOMAIN_V4 "IPv4/SNI domain" "$default_domain_v4"
  prompt DOMAIN_V6 "IPv6/SNI domain" "$default_domain_v6"
  prompt ACME_EMAIL "ACME email" "$ACME_EMAIL"
  prompt_keep_existing CF_TOKEN "Cloudflare DNS API token" "$CF_TOKEN" true
  prompt WARP_PROFILES_PER_INTERFACE "WARP profiles per egress interface" "$default_profiles_per_interface"
  validate_positive_integer "$WARP_PROFILES_PER_INTERFACE" "WARP profiles per egress interface"
  prompt EGRESS_INTERFACE_COUNT "How many egress interfaces" "$default_egress_interface_count"
  validate_positive_integer "$EGRESS_INTERFACE_COUNT" "Egress interface count"
  configure_generated_egress_interfaces "$EGRESS_INTERFACE_COUNT" "$WARP_PROFILES_PER_INTERFACE"
}

generate_new_config() {
  prepare_new_config_inputs
  load_passwords_from_config
  regenerate_passwords
  regenerate_all_warp_profiles
  write_singbox_config
  echo "New config generated."
}

change_sni() {
  prompt DOMAIN_V4 "IPv4/SNI domain" "$DOMAIN_V4"
  prompt DOMAIN_V6 "IPv6/SNI domain" "$DOMAIN_V6"
  write_singbox_config
  echo "SNI updated."
}

regenerate_selected_warp_menu() {
  local choice option selected_tag ipv4_choice ipv6_choice all_choice family index
  local -a ipv4_tags ipv6_tags all_tags

  echo
  echo "Select WARP profile to regenerate:"
  option=1
  for family in 4 6; do
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      echo "$option. warp-v${family}-${index}"
      ((option++))
    done
  done
  ipv4_choice=$option
  echo "$ipv4_choice. all IPv4 WARP"
  ((option++))
  ipv6_choice=$option
  echo "$ipv6_choice. all IPv6 WARP"
  ((option++))
  all_choice=$option
  echo "$all_choice. all WARP"
  echo "0. back"
  read -r -p "Choice: " choice

  if [[ "$choice" == "0" ]]; then
    return 0
  elif [[ "$choice" == "$ipv4_choice" ]]; then
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      ipv4_tags+=("$(warp_profile_tag 4 "$index")")
    done
    regenerate_warp_tags "${ipv4_tags[@]}"
  elif [[ "$choice" == "$ipv6_choice" ]]; then
    for ((index = 1; index <= WARP_INTERFACE_COUNT; index++)); do
      ipv6_tags+=("$(warp_profile_tag 6 "$index")")
    done
    regenerate_warp_tags "${ipv6_tags[@]}"
  elif [[ "$choice" == "$all_choice" ]]; then
    mapfile -t all_tags < <(all_warp_tags)
    regenerate_warp_tags "${all_tags[@]}"
  elif [[ "$choice" =~ ^[1-9][0-9]*$ && "$choice" -lt "$ipv4_choice" ]]; then
    if ((choice <= WARP_INTERFACE_COUNT)); then
      selected_tag="$(warp_profile_tag 4 "$choice")"
    else
      selected_tag="$(warp_profile_tag 6 "$((choice - WARP_INTERFACE_COUNT))")"
    fi
    regenerate_warp_tags "$selected_tag"
  else
    echo "Invalid choice"
    return 0
  fi

  write_singbox_config
  echo "Selected WARP profile(s) regenerated."
}

main_menu() {
  local choice

  while true; do
    echo
    echo "==== Sing-box HY2 + WARP Menu ===="
    echo "Current IPv4/SNI: $DOMAIN_V4"
    echo "Current IPv6/SNI: $DOMAIN_V6"
    echo "Current WARP slot total: $WARP_INTERFACE_COUNT"
    echo "Current WARP mode: $CURRENT_WARP_FLAVOR"
    echo "1. 重新生成密碼"
    echo "2. 重新生成所有 WARP"
    echo "3. 重新生成指定的 WARP"
    echo "4. 改變 SNI"
    echo "5. 輸出 proxy information"
    echo "6. 生成新的 config"
    echo "7. 寫入 secondary VNIC netplan"
    echo "0. 退出"
    read -r -p "Choice: " choice

    case "$choice" in
      1)
        regenerate_passwords
        write_singbox_config
        echo "Passwords regenerated."
        ;;
      2)
        regenerate_all_warp_profiles
        write_singbox_config
        echo "All WARP profiles regenerated."
        ;;
      3)
        regenerate_selected_warp_menu
        ;;
      4)
        change_sni
        ;;
      5)
        print_proxy_information
        ;;
      6)
        generate_new_config
        ;;
      7)
        write_secondary_vnic_netplan
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Invalid choice"
        ;;
    esac
  done
}

load_initial_state() {
  local existing_domain_v4 existing_domain_v6 existing_email existing_token existing_interface_count

  existing_domain_v4="$(config_json_value "server_name")"
  existing_domain_v6="$(config_acme_domain 2)"
  existing_email="$(config_json_value "email")"
  existing_token="$(config_json_value "api_token")"
  existing_interface_count="$(config_interface_count)"

  DOMAIN_V4="$existing_domain_v4"
  DOMAIN_V6="$existing_domain_v6"
  ACME_EMAIL="$existing_email"
  CF_TOKEN="$existing_token"

  [[ -n "$DOMAIN_V4" ]] || prompt DOMAIN_V4 "IPv4/SNI domain" "xxx.com"
  [[ -n "$DOMAIN_V6" ]] || prompt DOMAIN_V6 "IPv6/SNI domain" "xxx-v6.com"
  [[ -n "$ACME_EMAIL" ]] || prompt ACME_EMAIL "ACME email"
  [[ -n "$CF_TOKEN" ]] || prompt_keep_existing CF_TOKEN "Cloudflare DNS API token" "" true
  [[ -n "$WARP_INTERFACE_COUNT" ]] || WARP_INTERFACE_COUNT="${existing_interface_count:-2}"
  validate_positive_integer "$WARP_INTERFACE_COUNT" "WARP slot count"

  load_passwords_from_config
  CURRENT_WARP_FLAVOR="$(detect_existing_warp_flavor)"
  report_warp_generator_status

  if load_warp_profile_state "$CURRENT_WARP_FLAVOR"; then
    echo "Loaded existing WARP profiles from $CURRENT_WARP_FLAVOR."
  else
    echo "WARNING: No complete generated WARP profile set found. Use menu option 2 to regenerate WARP or option 6 to generate a new config."
  fi
}

main() {
  require_base_commands
  init_runtime
  load_initial_state
  main_menu
}

main "$@"
