# HY2 + WARP Sing-box Setup

This directory contains `setup-hy2-warp.sh`, a helper script for building a Sing-box config with:

- one Hysteria2 inbound on port `443`
- direct IPv4 and IPv6 outbounds
- four Cloudflare WARP WireGuard endpoints
- routing by Hysteria2 user:
  - `ipv4-1` -> direct IPv4
  - `ipv4-2` -> WARP IPv4 profile 1
  - `ipv4-3` -> WARP IPv4 profile 2
  - `ipv6-1` -> direct IPv6
  - `ipv6-2` -> WARP IPv6 profile 1
  - `ipv6-3` -> WARP IPv6 profile 2

The script prefers `warp-go` because it can export the `reserved` bytes required by modern Cloudflare WARP WireGuard handshakes. It can still fall back to `wgcf`.

## What The Script Does

When run, the script:

1. Downloads missing WARP tools from GitHub:
   - `warp-go` from `Fangliding/warp-go`
   - `wgcf` from `ViRb3/wgcf`
2. Generates four separate WARP profiles.
3. Writes `/etc/sing-box/config.json`.
4. Backs up the previous config to `config.json.bak-YYYYMMDD-HHMMSS`.
5. Runs `sing-box check`.
6. Enables and restarts the `sing-box` systemd service.
7. Prints Hysteria2 client entries and generated passwords.

## Requirements

Run as root on Linux.

Required commands:

- `sing-box`
- `systemctl`
- `openssl`
- `awk`
- `cp`
- `find`
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
/etc/sing-box/setup-hy2-warp.sh
```

The script will prompt for:

- IPv4/SNI domain
- IPv6/SNI domain
- ACME email
- Cloudflare DNS API token

If an existing Sing-box config already contains the ACME email or Cloudflare token, pressing Enter keeps the existing value.

## Force warp-go

Use this if you specifically want `warp-go` and do not want fallback behavior:

```bash
WARP_TOOL=warp-go /etc/sing-box/setup-hy2-warp.sh
```

## Force wgcf

Use this only if `warp-go` is not working for your environment:

```bash
WARP_TOOL=wgcf /etc/sing-box/setup-hy2-warp.sh
```

`wgcf` profiles do not provide real `reserved` bytes, so WARP connectivity may be less reliable.

## Disable Auto Download

If you already installed the binaries yourself:

```bash
AUTO_DOWNLOAD_WARP_TOOLS=false /etc/sing-box/setup-hy2-warp.sh
```

Default binary paths:

```bash
/root/warp-go/warp-go
/root/wgcf/wgcf
```

Override paths if needed:

```bash
WARP_GO_BIN=/custom/path/warp-go WGCF_BIN=/custom/path/wgcf /etc/sing-box/setup-hy2-warp.sh
```

## Important Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `CONFIG_PATH` | `/etc/sing-box/config.json` | Output Sing-box config path |
| `AUTO_DOWNLOAD_WARP_TOOLS` | `true` | Download missing `warp-go` and/or `wgcf` |
| `WARP_TOOL` | `auto` | `auto`, `warp-go`, or `wgcf` |
| `WARP_GO_BIN` | `/root/warp-go/warp-go` | `warp-go` binary path |
| `WARP_GO_BASE` | `/root/warp-go` | Directory for generated `warp-go` profiles |
| `WGCF_BIN` | `/root/wgcf/wgcf` | `wgcf` binary path |
| `WGCF_BASE` | `/root/wgcf` | Directory for generated `wgcf` profiles |
| `LISTEN_PORT` | `443` | Hysteria2 listen port |

## Generated Files

With `warp-go`, profile files are created under:

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
- `warp-go` is preferred because it exports the Sing-box `reserved` field.
- If WARP outbounds show as unavailable, the most common cause is a failed WireGuard handshake.
- The current route tags are preserved by the script, so existing client naming stays predictable.
