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
WARP_YG_ZEROTEAM_FAILED=false

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

  if [[ "$WARP_YG_ACCOUNT_SOURCE" == "warpapi" || "$WARP_YG_ZEROTEAM_FAILED" == "true" ]]; then
    write_warp_yg_fallback_conf "$output_path"
    return 0
  fi

  if fetch_url "https://api.zeroteam.top/warp?format=warp-go" "$output_path" && valid_warp_yg_conf "$output_path"; then
    return 0
  fi

  rm -f "$output_path"
  WARP_YG_ZEROTEAM_FAILED=true

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

need_cmd awk
need_cmd cp
need_cmd grep
need_cmd mkdir
need_cmd openssl
need_cmd sing-box
need_cmd systemctl
need_cmd tr

ensure_warp_tools
detect_warp_tool
if [[ "$WARP_TOOL" == "warp-yg" ]]; then
  ensure_warp_yg_repo
fi

EXISTING_ACME_EMAIL="$(config_json_value "email")"
EXISTING_CF_TOKEN="$(config_json_value "api_token")"

prompt DOMAIN_V4 "IPv4/SNI domain" "xxx.com"
prompt DOMAIN_V6 "IPv6/SNI domain" "xxx-v6.com"
prompt_keep_existing ACME_EMAIL "ACME email" "$EXISTING_ACME_EMAIL"
prompt_keep_existing CF_TOKEN "Cloudflare DNS API token" "$EXISTING_CF_TOKEN" true

echo "Generating HY2 passwords..."
PASS_IPV4_1="$(existing_or_rand_password "$(config_user_password "ipv4-1")")"
PASS_IPV4_2="$(existing_or_rand_password "$(config_user_password "ipv4-2")")"
PASS_IPV4_3="$(existing_or_rand_password "$(config_user_password "ipv4-3")")"
PASS_IPV6_1="$(existing_or_rand_password "$(config_user_password "ipv6-1")")"
PASS_IPV6_2="$(existing_or_rand_password "$(config_user_password "ipv6-2")")"
PASS_IPV6_3="$(existing_or_rand_password "$(config_user_password "ipv6-3")")"

echo "Generating four separate WARP profiles with $WARP_TOOL..."
for tag in warp-ipv4-1 warp-ipv4-2 warp-ipv6-1 warp-ipv6-2; do
  make_warp_profile "$tag"
done

if [[ "$WARP_TOOL" == "warp-yg" ]]; then
  WARP4_1_PROFILE="$WARP_YG_BASE/warp-ipv4-1/warp-yg-profile.conf"
  WARP4_2_PROFILE="$WARP_YG_BASE/warp-ipv4-2/warp-yg-profile.conf"
  WARP6_1_PROFILE="$WARP_YG_BASE/warp-ipv6-1/warp-yg-profile.conf"
  WARP6_2_PROFILE="$WARP_YG_BASE/warp-ipv6-2/warp-yg-profile.conf"
  WARP4_1_SINGBOX="$WARP_YG_BASE/warp-ipv4-1/warp-yg-singbox.json"
  WARP4_2_SINGBOX="$WARP_YG_BASE/warp-ipv4-2/warp-yg-singbox.json"
  WARP6_1_SINGBOX="$WARP_YG_BASE/warp-ipv6-1/warp-yg-singbox.json"
  WARP6_2_SINGBOX="$WARP_YG_BASE/warp-ipv6-2/warp-yg-singbox.json"
elif [[ "$WARP_TOOL" == "warp-go" ]]; then
  WARP4_1_PROFILE="$WARP_GO_BASE/warp-ipv4-1/warp-go-profile.conf"
  WARP4_2_PROFILE="$WARP_GO_BASE/warp-ipv4-2/warp-go-profile.conf"
  WARP6_1_PROFILE="$WARP_GO_BASE/warp-ipv6-1/warp-go-profile.conf"
  WARP6_2_PROFILE="$WARP_GO_BASE/warp-ipv6-2/warp-go-profile.conf"
  WARP4_1_SINGBOX="$WARP_GO_BASE/warp-ipv4-1/warp-go-singbox.json"
  WARP4_2_SINGBOX="$WARP_GO_BASE/warp-ipv4-2/warp-go-singbox.json"
  WARP6_1_SINGBOX="$WARP_GO_BASE/warp-ipv6-1/warp-go-singbox.json"
  WARP6_2_SINGBOX="$WARP_GO_BASE/warp-ipv6-2/warp-go-singbox.json"
else
  WARP4_1_PROFILE="$WGCF_BASE/warp-ipv4-1/wgcf-profile.conf"
  WARP4_2_PROFILE="$WGCF_BASE/warp-ipv4-2/wgcf-profile.conf"
  WARP6_1_PROFILE="$WGCF_BASE/warp-ipv6-1/wgcf-profile.conf"
  WARP6_2_PROFILE="$WGCF_BASE/warp-ipv6-2/wgcf-profile.conf"
  WARP4_1_SINGBOX=""
  WARP4_2_SINGBOX=""
  WARP6_1_SINGBOX=""
  WARP6_2_SINGBOX=""
fi

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

if [[ "$WARP_TOOL" == "warp-yg" || "$WARP_TOOL" == "warp-go" ]]; then
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
  [[ -n "${!value}" ]] || die "Failed to parse $value from generated WARP profiles"
done

DOMAIN_V4_JSON="$(json_escape "$DOMAIN_V4")"
DOMAIN_V6_JSON="$(json_escape "$DOMAIN_V6")"
ACME_EMAIL_JSON="$(json_escape "$ACME_EMAIL")"
CF_TOKEN_JSON="$(json_escape "$CF_TOKEN")"

if [[ -f "$CONFIG_PATH" ]]; then
  BACKUP_PATH="$CONFIG_PATH.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_PATH" "$BACKUP_PATH"
  chmod 600 "$BACKUP_PATH"
  echo "Backed up old config to $BACKUP_PATH"
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
    {
      "type": "wireguard",
      "tag": "warp-ipv4-1",
      "mtu": 1280,
      "address": [
        "$WARP4_1_ADDR"
      ],
      "private_key": "$WARP4_1_KEY",
      "peers": [
        {
          "address": "${WARP4_1_ENDPOINT:-engage.cloudflareclient.com}",
          "port": ${WARP4_1_PORT:-2408},
          "public_key": "$WARP4_1_PEER",
          "reserved": [$WARP4_1_RESERVED],
          "allowed_ips": [
            "0.0.0.0/0"
          ]
        }
      ],
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv4_only"
      }
    },
    {
      "type": "wireguard",
      "tag": "warp-ipv4-2",
      "mtu": 1280,
      "address": [
        "$WARP4_2_ADDR"
      ],
      "private_key": "$WARP4_2_KEY",
      "peers": [
        {
          "address": "${WARP4_2_ENDPOINT:-engage.cloudflareclient.com}",
          "port": ${WARP4_2_PORT:-2408},
          "public_key": "$WARP4_2_PEER",
          "reserved": [$WARP4_2_RESERVED],
          "allowed_ips": [
            "0.0.0.0/0"
          ]
        }
      ],
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv4_only"
      }
    },
    {
      "type": "wireguard",
      "tag": "warp-ipv6-1",
      "mtu": 1280,
      "address": [
        "$WARP6_1_ADDR"
      ],
      "private_key": "$WARP6_1_KEY",
      "peers": [
        {
          "address": "${WARP6_1_ENDPOINT:-engage.cloudflareclient.com}",
          "port": ${WARP6_1_PORT:-2408},
          "public_key": "$WARP6_1_PEER",
          "reserved": [$WARP6_1_RESERVED],
          "allowed_ips": [
            "::/0"
          ]
        }
      ],
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv6_only"
      }
    },
    {
      "type": "wireguard",
      "tag": "warp-ipv6-2",
      "mtu": 1280,
      "address": [
        "$WARP6_2_ADDR"
      ],
      "private_key": "$WARP6_2_KEY",
      "peers": [
        {
          "address": "${WARP6_2_ENDPOINT:-engage.cloudflareclient.com}",
          "port": ${WARP6_2_PORT:-2408},
          "public_key": "$WARP6_2_PEER",
          "reserved": [$WARP6_2_RESERVED],
          "allowed_ips": [
            "::/0"
          ]
        }
      ],
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv6_only"
      }
    }
  ],
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [
        {
          "name": "ipv4-1",
          "password": "$PASS_IPV4_1"
        },
        {
          "name": "ipv4-2",
          "password": "$PASS_IPV4_2"
        },
        {
          "name": "ipv4-3",
          "password": "$PASS_IPV4_3"
        },
        {
          "name": "ipv6-1",
          "password": "$PASS_IPV6_1"
        },
        {
          "name": "ipv6-2",
          "password": "$PASS_IPV6_2"
        },
        {
          "name": "ipv6-3",
          "password": "$PASS_IPV6_3"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN_V4_JSON",
        "acme": {
          "domain": [
            "$DOMAIN_V4_JSON",
            "$DOMAIN_V6_JSON"
          ],
          "email": "$ACME_EMAIL_JSON",
          "dns01_challenge": {
            "provider": "cloudflare",
            "api_token": "$CF_TOKEN_JSON"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-ipv4",
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv4_only"
      }
    },
    {
      "type": "direct",
      "tag": "direct-ipv6",
      "domain_resolver": {
        "server": "cf-dns",
        "strategy": "ipv6_only"
      }
    }
  ],
  "route": {
    "rules": [
      {
        "auth_user": [
          "ipv4-1",
          "ipv4-2",
          "ipv4-3"
        ],
        "action": "resolve",
        "strategy": "ipv4_only"
      },
      {
        "auth_user": [
          "ipv6-1",
          "ipv6-2",
          "ipv6-3"
        ],
        "action": "resolve",
        "strategy": "ipv6_only"
      },
      {
        "auth_user": [
          "ipv4-1",
          "ipv4-2",
          "ipv4-3"
        ],
        "ip_version": 6,
        "action": "reject"
      },
      {
        "auth_user": [
          "ipv6-1",
          "ipv6-2",
          "ipv6-3"
        ],
        "ip_version": 4,
        "action": "reject"
      },
      {
        "auth_user": "ipv4-1",
        "outbound": "direct-ipv4"
      },
      {
        "auth_user": "ipv4-2",
        "outbound": "warp-ipv4-1"
      },
      {
        "auth_user": "ipv4-3",
        "outbound": "warp-ipv4-2"
      },
      {
        "auth_user": "ipv6-1",
        "outbound": "direct-ipv6"
      },
      {
        "auth_user": "ipv6-2",
        "outbound": "warp-ipv6-1"
      },
      {
        "auth_user": "ipv6-3",
        "outbound": "warp-ipv6-2"
      }
    ],
    "final": "direct-ipv4"
  }
}
EOF

chmod 600 "$CONFIG_PATH"

echo "Checking sing-box config..."
sing-box check -c "$CONFIG_PATH"

echo "Restarting sing-box..."
systemctl enable --now sing-box
systemctl restart sing-box

echo
echo "Done. HY2 client entries using IPv4/SNI domain:"
echo "{ name: \"oracle hy ipv4-1 direct\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV4_1\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo "{ name: \"oracle hy ipv4-2 warp\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV4_2\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo "{ name: \"oracle hy ipv4-3 warp\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV4_3\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo "{ name: \"oracle hy ipv6-1 direct\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV6_1\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo "{ name: \"oracle hy ipv6-2 warp\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV6_2\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo "{ name: \"oracle hy ipv6-3 warp\", type: hysteria2, server: $DOMAIN_V4, port: $LISTEN_PORT, password: \"$PASS_IPV6_3\", sni: \"$DOMAIN_V4\", skip-cert-verify: false }"
echo
echo "Same passwords also work with server/sni: $DOMAIN_V6"
