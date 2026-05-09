# HY2 + WARP Sing-box Setup

This directory contains `warp-singbox.sh`, an interactive helper script for building a Sing-box config with:

- one Hysteria2 inbound on port `443`
- direct IPv4 and IPv6 outbounds
- a configurable number of Cloudflare WARP WireGuard endpoints per egress interface
- 2 or more SNI/ACME domains, up to 2 domains per selected egress interface
- routing by Hysteria2 user:
  - `direct-v4-N` -> direct IPv4 for WARP slot `N`
  - `warp-v4-N` -> WARP IPv4 profile `N`
  - `direct-v6-N` -> direct IPv6 for WARP slot `N`
  - `warp-v6-N` -> WARP IPv6 profile `N`

Menu option `6` asks how many WARP profiles to create per egress interface. For example, `3` means every selected real interface gets `3` IPv4 WARP profiles and `3` IPv6 WARP profiles. The script then expands that into internal slot numbers such as `warp-v4-1`, `warp-v4-2`, and so on.

When the generator asks for an egress interface, it prints a numbered interface list. Numeric input means that displayed list number, not the Linux link index from `ip link`.

The script now uses the yonggekkk `warp-yg` generation flow by default for WARP config creation, then exports WireGuard and Sing-box profile data with `warp-go`. It can still be forced to the older `warp-go` or `wgcf` modes with `WARP_TOOL`.

If `https://api.zeroteam.top/warp?format=warp-go` returns `503`, the script automatically switches to the `warp-yg` fallback generator for the rest of that run.

## What The Script Does

When run, the script shows a menu for:

1. Regenerating passwords
2. Regenerating all WARP profiles
3. Regenerating a selected WARP profile
4. Changing SNI domains
5. Printing proxy information
6. Generating a new full config
7. Writing `/etc/netplan/60-secondary-vnic.yaml` for VNIC policy routing

If existing Hysteria2 users are present in `config.json`, their passwords are preserved unless you choose password regeneration.
Menu option `6` prompts for the config values, the WARP profiles-per-interface count, and the egress interfaces. It creates fresh passwords, regenerates all WARP profiles, writes `config.json`, checks it, and restarts Sing-box.
Menu option `7` writes a policy-routing netplan file for real VNICs. It writes IPv4 and IPv6 source routing for secondary VNICs, plus IPv6 source routing for the primary VNIC so both public IPv6 addresses can receive proxy connections and reply through the same interface. It first uses unique secondary interfaces referenced by WARP slots, and if WARP slots are repeated on one real interface, it falls back to detecting other active real NICs such as `enp1s0`. Repeated interfaces are written once. It calculates each IPv4 gateway as the first usable IPv4 in that interface subnet, detects each IPv6 RA gateway from the default route, or uses overrides when set.

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

If values are missing from the existing config, the script opens the SNI/ACME submenu first. Manual mode then prompts for the per-domain entries, while generated mode asks for the base domain and hostname. After that it still prompts for:

- ACME email
- Cloudflare DNS API token

Menu option `4` opens a SNI/ACME domain input submenu. Manual input keeps the old behavior: choose the number of domains, then enter each domain. The allowed count is bounded: minimum `2`, maximum `egress interface count * 2`. For example, `2` egress interfaces can use `2`, `3`, or `4` certificate domains. The first domain is used as Sing-box `tls.server_name`; all selected domains are written to the ACME `domain` list and used when printing proxy information.

The generated SNI mode asks for:

- `SNI base domain`: the domain suffix to append. If `config.json` already has a domain, the script suggests a default by removing the first label. For example, `oracle-arm1.tsunhei.dpdns.org` becomes `tsunhei.dpdns.org`.
- `SNI hostname`: the host prefix. With hostname `sg-amd1` and `3` egress interfaces, the generated hostnames are `sg-amd1-1`, `sg-amd1-2`, `sg-amd1-3`, `sg-amd1-1-v6`, `sg-amd1-2-v6`, and `sg-amd1-3-v6`. With base domain `tsunhei.dpdns.org`, those become full domains such as `sg-amd1-1.tsunhei.dpdns.org`.

If an existing Sing-box config already contains these values, the menu opens directly.

## Proxy Naming

Proxy output uses this name pattern:

```text
oracle <country> <name> <type> <num>
```

For IPv6 entries, the `<name>` value gets `-v6` appended.
Each proxy information run prints `4 * SNI_DOMAIN_COUNT * WARP_INTERFACE_COUNT` entries. With the default two SNI domains, that is `8 * WARP_INTERFACE_COUNT`. `WARP_INTERFACE_COUNT` is the expanded internal slot total, so `2` egress interfaces with `3` profiles each becomes `6` internal slots.

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
| `SNI_DOMAIN_COUNT` | existing domain count or `2` | Number of SNI/ACME domains; must be at least `2` and no more than `2 * EGRESS_INTERFACE_COUNT` when generating a new config |
| `SNI_DOMAIN_N` | prompted | Optional domain override for index `N` when `SNI_DOMAIN_COUNT` is set; odd indexes are IPv4 labels, even indexes are IPv6 labels |
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
| `WARP_PROFILES_PER_INTERFACE` | `1` or derived from existing config | Number of IPv4 and IPv6 WARP profiles to generate per selected egress interface in menu option `6` |
| `EGRESS_INTERFACE_COUNT` | existing unique interfaces or `2` | Number of real egress interfaces selected in menu option `6` |
| `WARP_INTERFACE_COUNT` | auto-detected or expanded by option `6` | Internal total WARP/direct slot count |
| `SECONDARY_NETPLAN_PATH` | `/etc/netplan/60-secondary-vnic.yaml` | Netplan path for secondary VNIC policy routing |
| `SECONDARY_VNIC_COUNT` | `WARP_INTERFACE_COUNT` or `2` | Highest secondary VNIC index considered by option `7`; repeated real interfaces are deduplicated |
| `SECONDARY_VNIC_TABLE_BASE` | `100` | Routing table base; primary IPv6 uses `99`, interface 2 uses `100`, interface 3 uses `101`, etc. |
| `SECONDARY_VNIC_PRIORITY_BASE` | `100` | Routing policy priority base; primary IPv6 uses `99`, interface 2 uses `100`, interface 3 uses `101`, etc. |
| `SECONDARY_VNIC_N_INTERFACE` | `EGRESS_N_INTERFACE` | Interface override for secondary index `N` |
| `SECONDARY_VNIC_N_IPV4_CIDR` | detected | IPv4 CIDR override for secondary index `N`, for example `10.0.2.2/24` |
| `SECONDARY_VNIC_N_GATEWAY` | calculated | Gateway override for secondary index `N` |
| `SECONDARY_VNIC_N_IPV6` | detected | IPv6 source address override for VNIC index `N` |
| `SECONDARY_VNIC_N_IPV6_GATEWAY` | detected | IPv6 link-local gateway override for VNIC index `N` |
| `SECONDARY_VNIC_N_TABLE` | base + `N - 2` | Routing table override for secondary index `N` |
| `SECONDARY_VNIC_N_PRIORITY` | base + `N - 2` | Routing policy priority override for secondary index `N` |
| `SECONDARY_VNIC_INTERFACE` / `SECONDARY_VNIC_IPV4_CIDR` / `SECONDARY_VNIC_GATEWAY` / `SECONDARY_VNIC_IPV6` / `SECONDARY_VNIC_IPV6_GATEWAY` | index 2 only | Backward-compatible overrides for interface 2 |
| `EGRESS_INTERFACE` | unset | Optional default real interface for all WARP/direct slots |
| `EGRESS_1_INTERFACE` | `EGRESS_INTERFACE` or generated mapping | Interface for `*-1` direct and WARP egress |
| `EGRESS_2_INTERFACE` | `EGRESS_INTERFACE` or generated mapping | Interface for `*-2` direct and WARP egress |
| `EGRESS_N_INTERFACE` | generated mapping or prompted fallback | Interface for additional `*-N` direct and WARP egress; may repeat another slot |
| `EGRESS_1_IPV4` / `EGRESS_2_IPV4` | auto-detected | Optional IPv4 bind address override |
| `EGRESS_1_IPV6` / `EGRESS_2_IPV6` | auto-detected | Optional IPv6 bind address override |
| `EGRESS_N_IPV4` / `EGRESS_N_IPV6` | auto-detected | Optional bind address override for additional interfaces |

## Generated Files

With default `warp-yg`, profile files are created under:

```text
/root/warp-yg/warp-ipv4-1/
/root/warp-yg/warp-ipv4-2/
/root/warp-yg/warp-ipv4-N/
/root/warp-yg/warp-ipv6-1/
/root/warp-yg/warp-ipv6-2/
/root/warp-yg/warp-ipv6-N/
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
/root/warp-go/warp-ipv4-N/
/root/warp-go/warp-ipv6-1/
/root/warp-go/warp-ipv6-2/
/root/warp-go/warp-ipv6-N/
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
/root/wgcf/warp-ipv4-N/
/root/wgcf/warp-ipv6-1/
/root/wgcf/warp-ipv6-2/
/root/wgcf/warp-ipv6-N/
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
