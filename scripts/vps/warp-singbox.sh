#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-/etc/sing-box/config.json}"
WGCF_BIN="${WGCF_BIN:-/root/wgcf/wgcf}"
WGCF_BASE="${WGCF_BASE:-/root/wgcf}"
LISTEN_PORT="${LISTEN_PORT:-443}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
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

profile_value() {
  local profile="$1"
  local key="$2"
  awk -F'= *' -v k="$key" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$profile"
}

profile_address_v4() {
  local profile="$1"
  profile_value "$profile" "Address" | tr ',' '\n' | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 ~ /^[0-9.]+\/[0-9]+$/) { print; exit } }'
}

profile_address_v6() {
  local profile="$1"
  profile_value "$profile" "Address" | tr ',' '\n' | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 ~ /:/) { print; exit } }'
}

make_warp_profile() {
  local tag="$1"
  local dir="$WGCF_BASE/$tag"
  local profile="$dir/wgcf-profile.conf"

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
}

need_cmd awk
need_cmd cp
need_cmd mkdir
need_cmd openssl
need_cmd sing-box
need_cmd systemctl
need_cmd tr

[[ -x "$WGCF_BIN" ]] || die "wgcf binary not found or not executable at $WGCF_BIN"

EXISTING_ACME_EMAIL="$(config_json_value "email")"
EXISTING_CF_TOKEN="$(config_json_value "api_token")"

prompt DOMAIN_V4 "IPv4/SNI domain" "oracle-arm1.tsunhei.dpdns.org"
prompt DOMAIN_V6 "IPv6/SNI domain" "oracle-arm1-v6.tsunhei.dpdns.org"
prompt_keep_existing ACME_EMAIL "ACME email" "$EXISTING_ACME_EMAIL"
prompt_keep_existing CF_TOKEN "Cloudflare DNS API token" "$EXISTING_CF_TOKEN" true

echo "Generating HY2 passwords..."
PASS_IPV4_1="$(rand_password)"
PASS_IPV4_2="$(rand_password)"
PASS_IPV4_3="$(rand_password)"
PASS_IPV6_1="$(rand_password)"
PASS_IPV6_2="$(rand_password)"
PASS_IPV6_3="$(rand_password)"

echo "Generating four separate WARP profiles..."
for tag in warp-ipv4-1 warp-ipv4-2 warp-ipv6-1 warp-ipv6-2; do
  make_warp_profile "$tag"
done

WARP4_1_PROFILE="$WGCF_BASE/warp-ipv4-1/wgcf-profile.conf"
WARP4_2_PROFILE="$WGCF_BASE/warp-ipv4-2/wgcf-profile.conf"
WARP6_1_PROFILE="$WGCF_BASE/warp-ipv6-1/wgcf-profile.conf"
WARP6_2_PROFILE="$WGCF_BASE/warp-ipv6-2/wgcf-profile.conf"

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
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "$WARP4_1_PEER",
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
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "$WARP4_2_PEER",
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
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "$WARP6_1_PEER",
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
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "$WARP6_2_PEER",
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