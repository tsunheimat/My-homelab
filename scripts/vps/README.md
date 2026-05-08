# HY2 + WARP Sing-box Setup

This directory contains `warp-singbox.sh`, an interactive helper script for building a Sing-box config with:

- one Hysteria2 inbound on port `443`
- direct IPv4 and IPv6 outbounds
- four Cloudflare WARP WireGuard endpoints
- routing by Hysteria2 user:
  - `direct-v4-1` -> direct IPv4 on egress interface 1
  - `direct-v4-2` -> direct IPv4 on egress interface 2
  - `warp-v4-1` -> WARP IPv4 profile 1 on egress interface 1
  - `warp-v4-2` -> WARP IPv4 profile 2 on egress interface 2
  - `direct-v6-1` -> direct IPv6 on egress interface 1
  - `direct-v6-2` -> direct IPv6 on egress interface 2
  - `warp-v6-1` -> WARP IPv6 profile 1 on egress interface 1
  - `warp-v6-2` -> WARP IPv6 profile 2 on egress interface 2

The script now uses the yonggekkk `warp-yg` generation flow by default for WARP config creation, then exports WireGuard and Sing-box profile data with `warp-go`. It can still be forced to the older `warp-go` or `wgcf` modes with `WARP_TOOL`.

If `https://api.zeroteam.top/warp?format=warp-go` returns `503`, the script automatically switches to the `warp-yg` fallback generator for the rest of that run.

## What The Script Does

When run, the script shows a menu for:

1. Regenerating passwords
2. Regenerating all WARP profiles
3. Regenerating a selected WARP profile
4. Changing SNI
5. Printing proxy information

If existing Hysteria2 users are present in `config.json`, their passwords are preserved unless you choose password regeneration.

## Requirements

Run as root on Linux.

Required commands:

- `sing-box`
- `systemctl`
- `openssl`
- `awk`
- `cp`
- `find`
- `git`
- `grep`
- `head`
- `mkdir`
- `mktemp`
- `tr`
- `curl` or `wget`
- `tar` for `warp-go` release archives

The script currently auto-detects these CPU architectures:

- `amd64`
- `arm64`
- `armv7`
- `386`

## Basic Usage

Run:

```bash
/etc/sing-box/warp-singbox.sh
```

If values are missing from the existing config, the script will prompt for:

- IPv4/SNI domain
- IPv6/SNI domain
- ACME email
- Cloudflare DNS API token

If an existing Sing-box config already contains these values, the menu opens directly.

## Proxy Naming

Proxy output uses this name pattern:

```text
oracle <country> <name> <type> <num>
```

For IPv6 entries, the `<name>` value gets `-v6` appended.
Each proxy information run prints 16 entries: 8 for the IPv4 SNI and 8 for the IPv6 SNI.

## Default warp-yg

This is the default and uses the yonggekkk `warp-yg` account/config flow:

```bash
WARP_TOOL=warp-yg /etc/sing-box/warp-singbox.sh
```

## Force Legacy warp-go

Use this if you specifically want the old direct `warp-go --register` behavior:

```bash
WARP_TOOL=warp-go /etc/sing-box/warp-singbox.sh
```

## Force wgcf

Use this only if `warp-go` is not working for your environment:

```bash
WARP_TOOL=wgcf /etc/sing-box/warp-singbox.sh
```

`wgcf` profiles do not provide real `reserved` bytes, so WARP connectivity may be less reliable.

## Disable Auto Download

If you already installed the binaries yourself:

```bash
AUTO_DOWNLOAD_WARP_TOOLS=false /etc/sing-box/warp-singbox.sh
```

Default paths:

```bash
/root/warp-go/warp-go
/root/warp-yg
/root/wgcf/wgcf
```

Override paths if needed:

```bash
WARP_GO_BIN=/custom/path/warp-go WARP_YG_BASE=/custom/warp-yg /etc/sing-box/warp-singbox.sh
```

## Important Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `CONFIG_PATH` | `/etc/sing-box/config.json` | Output Sing-box config path |
| `AUTO_DOWNLOAD_WARP_TOOLS` | `true` | Download missing `warp-go` and/or `wgcf` |
| `WARP_TOOL` | `warp-yg` | `warp-yg`, `auto`, `warp-go`, or `wgcf` |
| `WARP_GO_BIN` | `/root/warp-go/warp-go` | `warp-go` binary path |
| `WARP_GO_BASE` | `/root/warp-go` | Directory for generated `warp-go` profiles |
| `WARP_YG_BASE` | `/root/warp-yg` | Directory for generated `warp-yg` profiles |
| `WARP_YG_ACCOUNT_SOURCE` | `auto` | `auto`, `zeroteam`, or `warpapi` account generation source |
| `WARP_YG_REPO_URL` | `https://github.com/yonggekkk/warp-yg.git` | `warp-yg` generator repo URL |
| `WARP_YG_REPO_DIR` | `/root/warp-yg/source` | Local checkout for the `warp-yg` generator repo |
| `WGCF_BIN` | `/root/wgcf/wgcf` | `wgcf` binary path |
| `WGCF_BASE` | `/root/wgcf` | Directory for generated `wgcf` profiles |
| `LISTEN_PORT` | `443` | Hysteria2 listen port |
| `EGRESS_1_INTERFACE` | `enp0s6` | Interface for `*-1` direct and WARP egress |
| `EGRESS_2_INTERFACE` | `enp1s0` | Interface for `*-2` direct and WARP egress |
| `EGRESS_1_IPV4` / `EGRESS_2_IPV4` | auto-detected | Optional IPv4 bind address override |
| `EGRESS_1_IPV6` / `EGRESS_2_IPV6` | auto-detected | Optional IPv6 bind address override |

## Generated Files

With default `warp-yg`, profile files are created under:

```text
/root/warp-yg/warp-ipv4-1/
/root/warp-yg/warp-ipv4-2/
/root/warp-yg/warp-ipv6-1/
/root/warp-yg/warp-ipv6-2/
```

Each profile directory contains:

- `warp.conf`
- `warp-yg-profile.conf`
- `warp-yg-singbox.json`
- a copied `warp-go` binary

With legacy `warp-go`, profile files are created under:

```text
/root/warp-go/warp-ipv4-1/
/root/warp-go/warp-ipv4-2/
/root/warp-go/warp-ipv6-1/
/root/warp-go/warp-ipv6-2/
```

Each profile directory contains:

- `warp.conf`
- `warp-go-profile.conf`
- `warp-go-singbox.json`
- a copied `warp-go` binary

With `wgcf`, profile files are created under:

```text
/root/wgcf/warp-ipv4-1/
/root/wgcf/warp-ipv4-2/
/root/wgcf/warp-ipv6-1/
/root/wgcf/warp-ipv6-2/
```

## Rollback

Before writing a new config, the script backs up the current config:

```text
/etc/sing-box/config.json.bak-YYYYMMDD-HHMMSS
```

To rollback manually:

```bash
cp /etc/sing-box/config.json.bak-YYYYMMDD-HHMMSS /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
systemctl restart sing-box
```

## Notes

- WARP+ is not required for this setup.
- `warp-yg` is the default WARP config generation flow.
- If WARP outbounds show as unavailable, the most common cause is a failed WireGuard handshake.
- The current route tags are preserved by the script, so existing client naming stays predictable.
