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
WARP_YG_FAIL_MARKER=""
EGRESS_1_INTERFACE="${EGRESS_1_INTERFACE:-enp0s6}"
EGRESS_2_INTERFACE="${EGRESS_2_INTERFACE:-enp1s0}"

declare -A USER_PASSWORDS
declare -A EGRESS_IFACES
declare -A EGRESS_V4_ADDRS
declare -A EGRESS_V6_ADDRS

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

load_egress_bindings() {
  local index iface_var v4_var v6_var iface v4_addr v6_addr

  for index in 1 2; do
    iface_var="EGRESS_${index}_INTERFACE"
    v4_var="EGRESS_${index}_IPV4"
    v6_var="EGRESS_${index}_IPV6"

    iface="${!iface_var-}"
    [[ -n "$iface" ]] || die "$iface_var is required"

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
      while (line !~ /\]/ && getline next_line) {
        line = line " " next_line
      }
      sub(/.*"reserved"[[:space:]]*:[[:space:]]*\[/, "", line)
      sub(/\].*/, "", line)
      gsub(/[[:space:]]+/, "", line)
      if (line != "") {
        print line
      }
      exit
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
      for index in 1 2; do
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
      for index in 1 2; do
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

set_warp_profile_paths() {
  local flavor="$1"

  case "$flavor" in
    warp-yg)
      WARP4_1_PROFILE="$WARP_YG_BASE/warp-ipv4-1/warp-yg-profile.conf"
      WARP4_2_PROFILE="$WARP_YG_BASE/warp-ipv4-2/warp-yg-profile.conf"
      WARP6_1_PROFILE="$WARP_YG_BASE/warp-ipv6-1/warp-yg-profile.conf"
      WARP6_2_PROFILE="$WARP_YG_BASE/warp-ipv6-2/warp-yg-profile.conf"
      WARP4_1_SINGBOX="$WARP_YG_BASE/warp-ipv4-1/warp-yg-singbox.json"
      WARP4_2_SINGBOX="$WARP_YG_BASE/warp-ipv4-2/warp-yg-singbox.json"
      WARP6_1_SINGBOX="$WARP_YG_BASE/warp-ipv6-1/warp-yg-singbox.json"
      WARP6_2_SINGBOX="$WARP_YG_BASE/warp-ipv6-2/warp-yg-singbox.json"
      ;;
    warp-go)
      WARP4_1_PROFILE="$WARP_GO_BASE/warp-ipv4-1/warp-go-profile.conf"
      WARP4_2_PROFILE="$WARP_GO_BASE/warp-ipv4-2/warp-go-profile.conf"
      WARP6_1_PROFILE="$WARP_GO_BASE/warp-ipv6-1/warp-go-profile.conf"
      WARP6_2_PROFILE="$WARP_GO_BASE/warp-ipv6-2/warp-go-profile.conf"
      WARP4_1_SINGBOX="$WARP_GO_BASE/warp-ipv4-1/warp-go-singbox.json"
      WARP4_2_SINGBOX="$WARP_GO_BASE/warp-ipv4-2/warp-go-singbox.json"
      WARP6_1_SINGBOX="$WARP_GO_BASE/warp-ipv6-1/warp-go-singbox.json"
      WARP6_2_SINGBOX="$WARP_GO_BASE/warp-ipv6-2/warp-go-singbox.json"
      ;;
    wgcf)
      WARP4_1_PROFILE="$WGCF_BASE/warp-ipv4-1/wgcf-profile.conf"
      WARP4_2_PROFILE="$WGCF_BASE/warp-ipv4-2/wgcf-profile.conf"
      WARP6_1_PROFILE="$WGCF_BASE/warp-ipv6-1/wgcf-profile.conf"
      WARP6_2_PROFILE="$WGCF_BASE/warp-ipv6-2/wgcf-profile.conf"
      WARP4_1_SINGBOX=""
      WARP4_2_SINGBOX=""
      WARP6_1_SINGBOX=""
      WARP6_2_SINGBOX=""
      ;;
    *)
      die "Unsupported WARP flavor: $flavor"
      ;;
  esac
}

load_warp_profile_state() {
  local flavor="${1:-$CURRENT_WARP_FLAVOR}"
  local value

  set_warp_profile_paths "$flavor"
  for value in "$WARP4_1_PROFILE" "$WARP4_2_PROFILE" "$WARP6_1_PROFILE" "$WARP6_2_PROFILE"; do
    [[ -f "$value" ]] || return 1
  done

  WARP4_1_KEY="$(profile_value "$WARP4_1_PROFILE" "PrivateKey")"
  WARP4_2_KEY="$(profile_value "$WARP4_2_PROFILE" "PrivateKey")"
  WARP6_1_KEY="$(profile_value "$WARP6_1_PROFILE" "PrivateKey")"
  WARP6_2_KEY="$(profile_value "$WARP6_2_PROFILE" "PrivateKey")"

  WARP4_1_ADDR="$(profile_address_v4 "$WARP4_1_PROFILE")"
  WARP4_2_ADDR="$(profile_address_v4 "$WARP4_2_PROFILE")"
  WARP6_1_ADDR="$(profile_address_v6 "$WARP6_1_PROFILE")"
  WARP6_2_ADDR="$(profile_address_v6 "$WARP6_2_PROFILE")"

  WARP4_1_PEER="$(profile_value "$WARP4_1_PROFILE" "PublicKey")"
  WARP4_2_PEER="$(profile_value "$WARP4_2_PROFILE" "PublicKey")"
  WARP6_1_PEER="$(profile_value "$WARP6_1_PROFILE" "PublicKey")"
  WARP6_2_PEER="$(profile_value "$WARP6_2_PROFILE" "PublicKey")"

  WARP4_1_ENDPOINT="$(profile_endpoint_host "$WARP4_1_PROFILE")"
  WARP4_2_ENDPOINT="$(profile_endpoint_host "$WARP4_2_PROFILE")"
  WARP6_1_ENDPOINT="$(profile_endpoint_host "$WARP6_1_PROFILE")"
  WARP6_2_ENDPOINT="$(profile_endpoint_host "$WARP6_2_PROFILE")"

  WARP4_1_PORT="$(profile_endpoint_port "$WARP4_1_PROFILE")"
  WARP4_2_PORT="$(profile_endpoint_port "$WARP4_2_PROFILE")"
  WARP6_1_PORT="$(profile_endpoint_port "$WARP6_1_PROFILE")"
  WARP6_2_PORT="$(profile_endpoint_port "$WARP6_2_PROFILE")"

  WARP4_1_RESERVED="0, 0, 0"
  WARP4_2_RESERVED="0, 0, 0"
  WARP6_1_RESERVED="0, 0, 0"
  WARP6_2_RESERVED="0, 0, 0"

  if [[ "$flavor" == "warp-yg" || "$flavor" == "warp-go" ]]; then
    WARP4_1_RESERVED="$(json_reserved "$WARP4_1_SINGBOX")"
    WARP4_2_RESERVED="$(json_reserved "$WARP4_2_SINGBOX")"
    WARP6_1_RESERVED="$(json_reserved "$WARP6_1_SINGBOX")"
    WARP6_2_RESERVED="$(json_reserved "$WARP6_2_SINGBOX")"

    [[ -n "$WARP4_1_RESERVED" ]] || WARP4_1_RESERVED="0, 0, 0"
    [[ -n "$WARP4_2_RESERVED" ]] || WARP4_2_RESERVED="0, 0, 0"
    [[ -n "$WARP6_1_RESERVED" ]] || WARP6_1_RESERVED="0, 0, 0"
    [[ -n "$WARP6_2_RESERVED" ]] || WARP6_2_RESERVED="0, 0, 0"
  fi

  for value in WARP4_1_KEY WARP4_2_KEY WARP6_1_KEY WARP6_2_KEY WARP4_1_ADDR WARP4_2_ADDR WARP6_1_ADDR WARP6_2_ADDR WARP4_1_PEER WARP4_2_PEER WARP6_1_PEER WARP6_2_PEER; do
    [[ -n "${!value}" ]] || return 1
  done
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

  load_warp_profile_state "$CURRENT_WARP_FLAVOR" || die "Failed to load generated WARP profiles"
}

render_warp_endpoint() {
  local family="$1"
  local index="$2"
  local base tag addr key peer endpoint port reserved allowed_ips resolver bind_address bind_key

  base="WARP${family}_${index}"
  tag="warp-v${family}-${index}"
  addr="${base}_ADDR"
  key="${base}_KEY"
  peer="${base}_PEER"
  endpoint="${base}_ENDPOINT"
  port="${base}_PORT"
  reserved="${base}_RESERVED"

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
        "${!addr}"
      ],
      "private_key": "${!key}",
      "peers": [
        {
          "address": "${!endpoint:-engage.cloudflareclient.com}",
          "port": ${!port:-2408},
          "public_key": "${!peer}",
          "reserved": [${!reserved}],
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
    for index in 1 2; do
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
      for index in 1 2; do
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
    for index in 1 2; do
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
    for index in 1 2; do
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
      for index in 1 2; do
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

  load_warp_profile_state "$CURRENT_WARP_FLAVOR" || die "Generated WARP profiles are missing; choose menu option 2 first"
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
        for index in 1 2; do
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

change_sni() {
  prompt DOMAIN_V4 "IPv4/SNI domain" "$DOMAIN_V4"
  prompt DOMAIN_V6 "IPv6/SNI domain" "$DOMAIN_V6"
  write_singbox_config
  echo "SNI updated."
}

regenerate_selected_warp_menu() {
  local choice

  echo
  echo "Select WARP profile to regenerate:"
  echo "1. warp-v4-1"
  echo "2. warp-v4-2"
  echo "3. warp-v6-1"
  echo "4. warp-v6-2"
  echo "5. all IPv4 WARP"
  echo "6. all IPv6 WARP"
  echo "7. all WARP"
  echo "0. back"
  read -r -p "Choice: " choice

  case "$choice" in
    1) regenerate_warp_tags "$(warp_profile_tag 4 1)" ;;
    2) regenerate_warp_tags "$(warp_profile_tag 4 2)" ;;
    3) regenerate_warp_tags "$(warp_profile_tag 6 1)" ;;
    4) regenerate_warp_tags "$(warp_profile_tag 6 2)" ;;
    5) regenerate_warp_tags "$(warp_profile_tag 4 1)" "$(warp_profile_tag 4 2)" ;;
    6) regenerate_warp_tags "$(warp_profile_tag 6 1)" "$(warp_profile_tag 6 2)" ;;
    7) regenerate_warp_tags "$(warp_profile_tag 4 1)" "$(warp_profile_tag 4 2)" "$(warp_profile_tag 6 1)" "$(warp_profile_tag 6 2)" ;;
    0) return 0 ;;
    *) echo "Invalid choice"; return 0 ;;
  esac

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
    echo "Current WARP mode: $CURRENT_WARP_FLAVOR"
    echo "1. 重新生成密碼"
    echo "2. 重新生成所有 WARP"
    echo "3. 重新生成指定的 WARP"
    echo "4. 改變 SNI"
    echo "5. 輸出 proxy information"
    echo "0. 退出"
    read -r -p "Choice: " choice

    case "$choice" in
      1)
        regenerate_passwords
        write_singbox_config
        echo "Passwords regenerated."
        ;;
      2)
        regenerate_warp_tags "$(warp_profile_tag 4 1)" "$(warp_profile_tag 4 2)" "$(warp_profile_tag 6 1)" "$(warp_profile_tag 6 2)"
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
  local existing_domain_v4 existing_domain_v6 existing_email existing_token

  existing_domain_v4="$(config_json_value "server_name")"
  existing_domain_v6="$(config_acme_domain 2)"
  existing_email="$(config_json_value "email")"
  existing_token="$(config_json_value "api_token")"

  DOMAIN_V4="$existing_domain_v4"
  DOMAIN_V6="$existing_domain_v6"
  ACME_EMAIL="$existing_email"
  CF_TOKEN="$existing_token"

  [[ -n "$DOMAIN_V4" ]] || prompt DOMAIN_V4 "IPv4/SNI domain" "xxx.com"
  [[ -n "$DOMAIN_V6" ]] || prompt DOMAIN_V6 "IPv6/SNI domain" "xxx-v6.com"
  [[ -n "$ACME_EMAIL" ]] || prompt ACME_EMAIL "ACME email"
  [[ -n "$CF_TOKEN" ]] || prompt_keep_existing CF_TOKEN "Cloudflare DNS API token" "" true

  load_passwords_from_config
  CURRENT_WARP_FLAVOR="$(detect_existing_warp_flavor)"

  if load_warp_profile_state "$CURRENT_WARP_FLAVOR"; then
    echo "Loaded existing WARP profiles from $CURRENT_WARP_FLAVOR."
  else
    echo "WARNING: No complete generated WARP profile set found. Use menu option 2 before writing config."
  fi
}

main() {
  require_base_commands
  init_runtime
  load_initial_state
  main_menu
}

main "$@"
