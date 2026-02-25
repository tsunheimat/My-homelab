#!/bin/bash
#
# PVE VM Hardware Fingerprint Editor
# Edits /etc/pve/qemu-server/<vmid>.conf to spoof hardware identifiers
# Run on the Proxmox VE host as root
#
# Usage: bash pve-fingerprint.sh [vmid]
#

set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================
PVE_CONF_DIR="/etc/pve/qemu-server"
BACKUP_DIR="/root/vm-fingerprint-backups"
LOG_FILE="/root/vm-fingerprint.log"

# Colors
RED='\033[0;91m'
GREEN='\033[0;92m'
YELLOW='\033[0;93m'
BLUE='\033[0;94m'
MAGENTA='\033[0;95m'
CYAN='\033[0;96m'
WHITE='\033[0;97m'
GRAY='\033[0;90m'
RESET='\033[0m'

# ============================================================================
# UTILITY
# ============================================================================

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                            ║"
    echo "  ║     PVE  VM  Hardware  Fingerprint  Editor  v1.0           ║"
    echo "  ║     Browser Fingerprint Environment Tool                   ║"
    echo "  ║                                                            ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_sep() {
    echo -e "  ${GRAY}──────────────────────────────────────────────────────────${RESET}"
}

print_ok()   { echo -e "  ${GREEN}[OK]${RESET} $1"; }
print_err()  { echo -e "  ${RED}[!!]${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}[>>]${RESET} $1"; }

# Generate random hex string of given length
rand_hex() {
    local len=${1:-12}
    head -c 64 /dev/urandom | xxd -p | tr -d '\n' | head -c "$len"
}

# Generate random MAC (locally administered, unicast)
rand_mac() {
    local first_octet=$(printf '%02X' $(( (RANDOM % 64) * 4 + 2 )))
    local rest=$(rand_hex 10 | sed 's/\(..\)/:\1/g' | tr '[:lower:]' '[:upper:]')
    echo "${first_octet}${rest}"
}

# Generate random UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"
}

# Generate random serial (alphanumeric)
rand_serial() {
    local len=${1:-16}
    cat /dev/urandom | tr -dc 'A-Z0-9' | head -c "$len"
}

# Generate random computer-style name
rand_hostname() {
    local prefixes=("DESKTOP" "PC" "WIN" "LAPTOP" "WORKSTATION")
    local prefix=${prefixes[$((RANDOM % ${#prefixes[@]}))]}
    local suffix=$(rand_serial 7)
    echo "${prefix}-${suffix}"
}

# ============================================================================
# VM CONFIG HELPERS
# ============================================================================

get_conf_file() {
    echo "${PVE_CONF_DIR}/${1}.conf"
}

conf_exists() {
    [[ -f "$(get_conf_file "$1")" ]]
}

backup_conf() {
    local vmid=$1
    local conf=$(get_conf_file "$vmid")
    mkdir -p "$BACKUP_DIR"
    local stamp=$(date '+%Y%m%d_%H%M%S')
    cp "$conf" "${BACKUP_DIR}/${vmid}_${stamp}.conf"
    print_ok "Backup: ${BACKUP_DIR}/${vmid}_${stamp}.conf"
    log_action "BACKUP VM${vmid} => ${BACKUP_DIR}/${vmid}_${stamp}.conf"
}

# Read a key from VM conf (first match)
conf_get() {
    local vmid=$1 key=$2
    local conf=$(get_conf_file "$vmid")
    grep -m1 "^${key}:" "$conf" 2>/dev/null | sed "s/^${key}: *//"
}

# Set a key in VM conf (replace if exists, append if not)
conf_set() {
    local vmid=$1 key=$2 value=$3
    local conf=$(get_conf_file "$vmid")
    if grep -q "^${key}:" "$conf" 2>/dev/null; then
        sed -i "s|^${key}:.*|${key}: ${value}|" "$conf"
    else
        echo "${key}: ${value}" >> "$conf"
    fi
}

# Remove a key from VM conf
conf_del() {
    local vmid=$1 key=$2
    local conf=$(get_conf_file "$vmid")
    sed -i "/^${key}:/d" "$conf"
}

# Parse smbios1 field
smbios_get_field() {
    local smbios_line=$1 field=$2
    echo "$smbios_line" | grep -oP "${field}=[^,]*" | sed "s/${field}=//"
}

# Build smbios1 line from associative values
build_smbios1() {
    local uuid=$1 manufacturer=$2 product=$3 version=$4 serial=$5 sku=$6 family=$7
    local parts=()
    [[ -n "$uuid" ]]         && parts+=("uuid=${uuid}")
    [[ -n "$manufacturer" ]] && parts+=("manufacturer=${manufacturer}")
    [[ -n "$product" ]]      && parts+=("product=${product}")
    [[ -n "$version" ]]      && parts+=("version=${version}")
    [[ -n "$serial" ]]       && parts+=("serial=${serial}")
    [[ -n "$sku" ]]          && parts+=("sku=${sku}")
    [[ -n "$family" ]]       && parts+=("family=${family}")
    local IFS=','
    echo "${parts[*]}"
}

# ============================================================================
# LIST VMs
# ============================================================================

list_vms() {
    print_banner
    echo -e "  ${MAGENTA}AVAILABLE VMs${RESET}"
    print_sep
    echo ""

    if [[ ! -d "$PVE_CONF_DIR" ]]; then
        print_err "PVE config directory not found: $PVE_CONF_DIR"
        return 1
    fi

    printf "  ${CYAN}%-8s %-25s %-10s${RESET}\n" "VMID" "NAME" "STATUS"
    print_sep

    for conf in "${PVE_CONF_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local vmid=$(basename "$conf" .conf)
        local name=$(grep -m1 "^name:" "$conf" | sed 's/^name: *//')
        local status="stopped"
        if qm status "$vmid" 2>/dev/null | grep -q "running"; then
            status="running"
        fi
        local status_color=$RED
        [[ "$status" == "running" ]] && status_color=$GREEN
        printf "  %-8s %-25s ${status_color}%-10s${RESET}\n" "$vmid" "${name:-(unnamed)}" "$status"
    done
    echo ""
}

# ============================================================================
# VIEW FINGERPRINT
# ============================================================================

view_fingerprint() {
    local vmid=$1
    print_banner
    echo -e "  ${MAGENTA}VM ${vmid} — CURRENT FINGERPRINT${RESET}"
    print_sep
    echo ""

    local conf=$(get_conf_file "$vmid")
    local name=$(conf_get "$vmid" "name")

    echo -e "  ${YELLOW}  VM Name:        ${WHITE}${name:-(not set)}${RESET}"

    # SMBIOS
    local smbios=$(conf_get "$vmid" "smbios1")
    if [[ -n "$smbios" ]]; then
        local s_uuid=$(smbios_get_field "$smbios" "uuid")
        local s_mfr=$(smbios_get_field "$smbios" "manufacturer")
        local s_prod=$(smbios_get_field "$smbios" "product")
        local s_ver=$(smbios_get_field "$smbios" "version")
        local s_serial=$(smbios_get_field "$smbios" "serial")
        local s_sku=$(smbios_get_field "$smbios" "sku")
        local s_family=$(smbios_get_field "$smbios" "family")

        echo -e "  ${YELLOW}  UUID:           ${WHITE}${s_uuid:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  Manufacturer:   ${WHITE}${s_mfr:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  Product:        ${WHITE}${s_prod:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  Version:        ${WHITE}${s_ver:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  Serial:         ${WHITE}${s_serial:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  SKU:            ${WHITE}${s_sku:-(not set)}${RESET}"
        echo -e "  ${YELLOW}  Family:         ${WHITE}${s_family:-(not set)}${RESET}"
    else
        echo -e "  ${GRAY}  smbios1: (not configured)${RESET}"
    fi

    echo ""
    print_sep
    echo -e "  ${MAGENTA}NETWORK${RESET}"
    print_sep
    echo ""

    # Network adapters (net0, net1, ...)
    for i in $(seq 0 7); do
        local netline=$(conf_get "$vmid" "net${i}")
        [[ -z "$netline" ]] && continue
        local mac=$(echo "$netline" | grep -oP '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}')
        local model=$(echo "$netline" | grep -oP '^\w+')
        echo -e "    ${CYAN}net${i}${RESET}  ${WHITE}${mac:-unknown}${RESET}  ${GRAY}(${model})${RESET}"
    done

    echo ""
    print_sep
    echo -e "  ${MAGENTA}DISKS${RESET}"
    print_sep
    echo ""

    # Disk lines (scsi0, sata0, virtio0, ide0, etc.)
    for prefix in scsi sata virtio ide; do
        for i in $(seq 0 7); do
            local diskline=$(conf_get "$vmid" "${prefix}${i}")
            [[ -z "$diskline" ]] && continue
            local serial_val=$(echo "$diskline" | grep -oP 'serial=[^,]*' | sed 's/serial=//')
            echo -e "    ${CYAN}${prefix}${i}${RESET}  ${GRAY}${diskline}${RESET}"
            [[ -n "$serial_val" ]] && echo -e "           ${YELLOW}Serial: ${WHITE}${serial_val}${RESET}"
        done
    done

    echo ""
    print_sep
    echo -e "  ${MAGENTA}OTHER${RESET}"
    print_sep
    echo ""

    local cpu=$(conf_get "$vmid" "cpu")
    local machine=$(conf_get "$vmid" "machine")
    local bios=$(conf_get "$vmid" "bios")
    local args=$(conf_get "$vmid" "args")

    echo -e "  ${YELLOW}  CPU:            ${WHITE}${cpu:-(default)}${RESET}"
    echo -e "  ${YELLOW}  Machine:        ${WHITE}${machine:-(default)}${RESET}"
    echo -e "  ${YELLOW}  BIOS:           ${WHITE}${bios:-(default/seabios)}${RESET}"
    [[ -n "$args" ]] && echo -e "  ${YELLOW}  QEMU Args:      ${WHITE}${args}${RESET}"

    echo ""
}

# ============================================================================
# EDIT SMBIOS
# ============================================================================

edit_smbios() {
    local vmid=$1
    print_banner
    echo -e "  ${MAGENTA}EDIT SMBIOS — VM ${vmid}${RESET}"
    print_sep
    echo ""

    local smbios=$(conf_get "$vmid" "smbios1")
    local s_uuid=$(smbios_get_field "$smbios" "uuid")
    local s_mfr=$(smbios_get_field "$smbios" "manufacturer")
    local s_prod=$(smbios_get_field "$smbios" "product")
    local s_ver=$(smbios_get_field "$smbios" "version")
    local s_serial=$(smbios_get_field "$smbios" "serial")
    local s_sku=$(smbios_get_field "$smbios" "sku")
    local s_family=$(smbios_get_field "$smbios" "family")

    echo -e "  Current: ${GRAY}${smbios:-(empty)}${RESET}"
    echo ""
    echo -e "    ${CYAN}[1]${RESET} Randomize ALL SMBIOS fields"
    echo -e "    ${CYAN}[2]${RESET} Set UUID only"
    echo -e "    ${CYAN}[3]${RESET} Set Manufacturer"
    echo -e "    ${CYAN}[4]${RESET} Set Product Name"
    echo -e "    ${CYAN}[5]${RESET} Set Serial Number"
    echo -e "    ${CYAN}[6]${RESET} Set from preset (look like real hardware)"
    echo -e "    ${GRAY}[0]${RESET} Back"
    echo ""

    read -rp "  Select: " choice

    case "$choice" in
        1)
            s_uuid=$(rand_uuid)
            s_serial=$(rand_serial 20)
            s_sku=$(rand_serial 12)
            # Pick a realistic manufacturer/product combo
            local combos=(
                "Dell Inc.|OptiPlex 7080|1.0|Desktop"
                "Lenovo|ThinkCentre M920q|ThinkCentre|ThinkCentre"
                "HP|HP EliteDesk 800 G5|1.0|103C_53307F"
                "ASUS|PRIME B550M-A|Rev 1.xx|Desktop"
                "Gigabyte Technology Co., Ltd.|B550 AORUS ELITE|x.x|Desktop"
                "MSI|MS-7C91|1.0|Desktop"
                "Acer|Aspire TC-895|V:1.1|Aspire"
                "Micro-Star International Co., Ltd.|MAG B660M MORTAR|1.0|Desktop"
            )
            local combo=${combos[$((RANDOM % ${#combos[@]}))]}
            IFS='|' read -r s_mfr s_prod s_ver s_family <<< "$combo"
            ;;
        2)
            read -rp "  UUID (blank=random): " input
            s_uuid=${input:-$(rand_uuid)}
            ;;
        3)
            read -rp "  Manufacturer: " s_mfr
            ;;
        4)
            read -rp "  Product: " s_prod
            ;;
        5)
            read -rp "  Serial (blank=random): " input
            s_serial=${input:-$(rand_serial 20)}
            ;;
        6)
            echo ""
            echo -e "    ${CYAN}[1]${RESET} Dell OptiPlex 7080"
            echo -e "    ${CYAN}[2]${RESET} Lenovo ThinkCentre M920q"
            echo -e "    ${CYAN}[3]${RESET} HP EliteDesk 800 G5"
            echo -e "    ${CYAN}[4]${RESET} ASUS PRIME B550M-A"
            echo -e "    ${CYAN}[5]${RESET} Gigabyte B550 AORUS ELITE"
            echo -e "    ${CYAN}[6]${RESET} MSI MAG B660M MORTAR"
            echo -e "    ${CYAN}[7]${RESET} Acer Aspire TC-895"
            echo ""
            read -rp "  Select preset: " preset
            s_uuid=$(rand_uuid)
            s_serial=$(rand_serial 20)
            s_sku=$(rand_serial 12)
            case "$preset" in
                1) s_mfr="Dell Inc."; s_prod="OptiPlex 7080"; s_ver="1.0"; s_family="Desktop" ;;
                2) s_mfr="Lenovo"; s_prod="ThinkCentre M920q"; s_ver="ThinkCentre"; s_family="ThinkCentre" ;;
                3) s_mfr="HP"; s_prod="HP EliteDesk 800 G5"; s_ver="1.0"; s_family="103C_53307F" ;;
                4) s_mfr="ASUS"; s_prod="PRIME B550M-A"; s_ver="Rev 1.xx"; s_family="Desktop" ;;
                5) s_mfr="Gigabyte Technology Co., Ltd."; s_prod="B550 AORUS ELITE"; s_ver="x.x"; s_family="Desktop" ;;
                6) s_mfr="Micro-Star International Co., Ltd."; s_prod="MAG B660M MORTAR"; s_ver="1.0"; s_family="Desktop" ;;
                7) s_mfr="Acer"; s_prod="Aspire TC-895"; s_ver="V:1.1"; s_family="Aspire" ;;
                *) print_err "Invalid preset"; return ;;
            esac
            ;;
        0|"") return ;;
        *) print_err "Invalid option"; return ;;
    esac

    local new_smbios=$(build_smbios1 "$s_uuid" "$s_mfr" "$s_prod" "$s_ver" "$s_serial" "$s_sku" "$s_family")
    conf_set "$vmid" "smbios1" "$new_smbios"

    echo ""
    print_ok "smbios1: $new_smbios"
    log_action "VM${vmid} smbios1 => $new_smbios"
}

# ============================================================================
# EDIT MAC ADDRESS
# ============================================================================

edit_mac() {
    local vmid=$1
    print_banner
    echo -e "  ${MAGENTA}EDIT MAC ADDRESS — VM ${vmid}${RESET}"
    print_sep
    echo ""

    # List network interfaces
    local found=0
    for i in $(seq 0 7); do
        local netline=$(conf_get "$vmid" "net${i}")
        [[ -z "$netline" ]] && continue
        found=1
        local mac=$(echo "$netline" | grep -oP '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}')
        local model=$(echo "$netline" | grep -oP '^\w+')
        echo -e "    ${CYAN}[${i}]${RESET} net${i}: ${WHITE}${mac}${RESET} (${model})"
    done

    if [[ $found -eq 0 ]]; then
        print_err "No network interfaces found."
        return
    fi

    echo ""
    echo -e "    ${GREEN}[A]${RESET} Randomize ALL MACs"
    echo -e "    ${GRAY}[B]${RESET} Back"
    echo ""
    read -rp "  Select interface: " choice

    if [[ "$choice" == "A" || "$choice" == "a" ]]; then
        for i in $(seq 0 7); do
            local netline=$(conf_get "$vmid" "net${i}")
            [[ -z "$netline" ]] && continue
            local new_mac=$(rand_mac)
            local old_mac=$(echo "$netline" | grep -oP '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}')
            local new_line=$(echo "$netline" | sed "s/${old_mac}/${new_mac}/")
            conf_set "$vmid" "net${i}" "$new_line"
            print_ok "net${i}: ${new_mac}"
            log_action "VM${vmid} net${i} MAC => ${new_mac}"
        done
        return
    fi

    [[ "$choice" == "B" || "$choice" == "b" ]] && return

    local netline=$(conf_get "$vmid" "net${choice}")
    if [[ -z "$netline" ]]; then
        print_err "Interface net${choice} not found."
        return
    fi

    echo ""
    echo -e "    ${CYAN}[1]${RESET} Random MAC"
    echo -e "    ${CYAN}[2]${RESET} Custom MAC"
    read -rp "  Choose: " mac_choice

    local new_mac
    case "$mac_choice" in
        1) new_mac=$(rand_mac) ;;
        2) read -rp "  Enter MAC (XX:XX:XX:XX:XX:XX): " new_mac ;;
        *) return ;;
    esac

    local old_mac=$(echo "$netline" | grep -oP '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}')
    local new_line=$(echo "$netline" | sed "s/${old_mac}/${new_mac}/")
    conf_set "$vmid" "net${choice}" "$new_line"
    echo ""
    print_ok "net${choice}: ${old_mac} => ${new_mac}"
    log_action "VM${vmid} net${choice} MAC: ${old_mac} => ${new_mac}"
}

# ============================================================================
# EDIT DISK SERIAL
# ============================================================================

edit_disk_serial() {
    local vmid=$1
    print_banner
    echo -e "  ${MAGENTA}EDIT DISK SERIAL — VM ${vmid}${RESET}"
    print_sep
    echo ""

    local disks=()
    for prefix in scsi sata virtio ide; do
        for i in $(seq 0 7); do
            local diskline=$(conf_get "$vmid" "${prefix}${i}")
            [[ -z "$diskline" ]] && continue
            disks+=("${prefix}${i}")
            local serial_val=$(echo "$diskline" | grep -oP 'serial=[^,]*' | sed 's/serial=//')
            echo -e "    ${CYAN}[${#disks[@]}]${RESET} ${prefix}${i}: serial=${WHITE}${serial_val:-(none)}${RESET}"
        done
    done

    if [[ ${#disks[@]} -eq 0 ]]; then
        print_err "No disks found."
        return
    fi

    echo ""
    echo -e "    ${GREEN}[A]${RESET} Add/randomize serial on ALL disks"
    echo -e "    ${GRAY}[0]${RESET} Back"
    echo ""
    read -rp "  Select disk: " choice

    if [[ "$choice" == "A" || "$choice" == "a" ]]; then
        for disk in "${disks[@]}"; do
            local diskline=$(conf_get "$vmid" "$disk")
            local new_serial=$(rand_serial 20)
            # Remove old serial if present, then add new
            local cleaned=$(echo "$diskline" | sed 's/,serial=[^,]*//' | sed 's/serial=[^,]*//')
            conf_set "$vmid" "$disk" "${cleaned},serial=${new_serial}"
            print_ok "${disk}: serial=${new_serial}"
            log_action "VM${vmid} ${disk} serial => ${new_serial}"
        done
        return
    fi

    [[ "$choice" == "0" ]] && return

    local idx=$((choice - 1))
    if [[ $idx -lt 0 || $idx -ge ${#disks[@]} ]]; then
        print_err "Invalid selection."
        return
    fi

    local disk=${disks[$idx]}
    local diskline=$(conf_get "$vmid" "$disk")
    read -rp "  Serial (blank=random): " input
    local new_serial=${input:-$(rand_serial 20)}

    local cleaned=$(echo "$diskline" | sed 's/,serial=[^,]*//' | sed 's/serial=[^,]*//')
    conf_set "$vmid" "$disk" "${cleaned},serial=${new_serial}"
    print_ok "${disk}: serial=${new_serial}"
    log_action "VM${vmid} ${disk} serial => ${new_serial}"
}

# ============================================================================
# EDIT QEMU ARGS (advanced SMBIOS type 0,2,3)
# ============================================================================

edit_qemu_args() {
    local vmid=$1
    print_banner
    echo -e "  ${MAGENTA}ADVANCED QEMU ARGS — VM ${vmid}${RESET}"
    print_sep
    echo ""

    local current_args=$(conf_get "$vmid" "args")
    echo -e "  Current args: ${GRAY}${current_args:-(none)}${RESET}"
    echo ""
    echo -e "    ${CYAN}[1]${RESET} Add SMBIOS Type 0 (BIOS vendor/version)"
    echo -e "    ${CYAN}[2]${RESET} Add SMBIOS Type 2 (Baseboard info)"
    echo -e "    ${CYAN}[3]${RESET} Add SMBIOS Type 3 (Chassis info)"
    echo -e "    ${CYAN}[4]${RESET} Add ALL SMBIOS types (realistic preset)"
    echo -e "    ${CYAN}[5]${RESET} Set custom args"
    echo -e "    ${RED}[D]${RESET} Clear all args"
    echo -e "    ${GRAY}[0]${RESET} Back"
    echo ""
    read -rp "  Select: " choice

    # Remove existing smbios args, keep others
    local clean_args=$(echo "$current_args" | sed 's/-smbios [^ ]*//g' | xargs)

    case "$choice" in
        1)
            local bios_vendor="American Megatrends Inc."
            local bios_version="$(( RANDOM % 5 + 1 )).$(( RANDOM % 30 ))$(rand_serial 1)"
            local bios_date="$(( RANDOM % 12 + 1 ))/$(( RANDOM % 28 + 1 ))/$(( RANDOM % 4 + 2021 ))"
            local new_arg="-smbios type=0,vendor=${bios_vendor},version=${bios_version},date=${bios_date}"
            conf_set "$vmid" "args" "${clean_args} ${new_arg}"
            print_ok "BIOS: ${bios_vendor} v${bios_version} (${bios_date})"
            ;;
        2)
            local board_mfr="ASUSTeK COMPUTER INC."
            local board_prod="PRIME B550M-A"
            local board_serial=$(rand_serial 12)
            local new_arg="-smbios type=2,manufacturer=${board_mfr},product=${board_prod},serial=${board_serial}"
            conf_set "$vmid" "args" "${clean_args} ${new_arg}"
            print_ok "Baseboard: ${board_mfr} ${board_prod} (${board_serial})"
            ;;
        3)
            local chassis_mfr="Default string"
            local chassis_serial=$(rand_serial 12)
            local chassis_sku="Default string"
            local new_arg="-smbios type=3,manufacturer=${chassis_mfr},serial=${chassis_serial},sku=${chassis_sku}"
            conf_set "$vmid" "args" "${clean_args} ${new_arg}"
            print_ok "Chassis serial: ${chassis_serial}"
            ;;
        4)
            local bios_vendor="American Megatrends Inc."
            local bios_ver="$(( RANDOM % 5 + 1 )).$(( RANDOM % 30 ))"
            local bios_date="$(( RANDOM % 12 + 1 ))/$(( RANDOM % 28 + 1 ))/$(( RANDOM % 4 + 2021 ))"
            local board_mfr="ASUSTeK COMPUTER INC."
            local board_prod="PRIME B550M-A"
            local board_serial=$(rand_serial 12)
            local chassis_serial=$(rand_serial 12)
            local all_args="-smbios type=0,vendor=${bios_vendor},version=${bios_ver},date=${bios_date}"
            all_args="${all_args} -smbios type=2,manufacturer=${board_mfr},product=${board_prod},serial=${board_serial}"
            all_args="${all_args} -smbios type=3,manufacturer=Default string,serial=${chassis_serial}"
            conf_set "$vmid" "args" "${clean_args} ${all_args}"
            print_ok "All SMBIOS types set with realistic values"
            ;;
        5)
            read -rp "  Enter custom args: " custom
            conf_set "$vmid" "args" "$custom"
            print_ok "Args set"
            ;;
        D|d)
            conf_del "$vmid" "args"
            print_ok "Args cleared"
            ;;
        *) return ;;
    esac
    log_action "VM${vmid} args updated"
}

# ============================================================================
# RANDOMIZE ALL
# ============================================================================

randomize_all() {
    local vmid=$1
    print_banner
    echo -e "  ${RED}RANDOMIZE ALL — VM ${vmid}${RESET}"
    print_sep
    echo ""
    echo -e "  This will randomize: SMBIOS, MAC, disk serial, QEMU args"
    echo ""
    read -rp "  Type 'YES' to confirm: " confirm
    [[ "$confirm" != "YES" ]] && { print_warn "Cancelled."; return; }

    echo ""
    backup_conf "$vmid"
    echo ""

    # 1) SMBIOS
    local combos=(
        "Dell Inc.|OptiPlex 7080|1.0|Desktop"
        "Lenovo|ThinkCentre M920q|ThinkCentre|ThinkCentre"
        "HP|HP EliteDesk 800 G5|1.0|103C_53307F"
        "ASUS|PRIME B550M-A|Rev 1.xx|Desktop"
        "Gigabyte Technology Co., Ltd.|B550 AORUS ELITE|x.x|Desktop"
    )
    local combo=${combos[$((RANDOM % ${#combos[@]}))]}
    IFS='|' read -r mfr prod ver fam <<< "$combo"
    local uuid=$(rand_uuid)
    local serial=$(rand_serial 20)
    local sku=$(rand_serial 12)
    local smbios=$(build_smbios1 "$uuid" "$mfr" "$prod" "$ver" "$serial" "$sku" "$fam")
    conf_set "$vmid" "smbios1" "$smbios"
    print_ok "SMBIOS: ${mfr} ${prod}"

    # 2) MACs
    for i in $(seq 0 7); do
        local netline=$(conf_get "$vmid" "net${i}")
        [[ -z "$netline" ]] && continue
        local new_mac=$(rand_mac)
        local old_mac=$(echo "$netline" | grep -oP '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}')
        [[ -n "$old_mac" ]] && {
            local new_line=$(echo "$netline" | sed "s/${old_mac}/${new_mac}/")
            conf_set "$vmid" "net${i}" "$new_line"
            print_ok "net${i}: ${new_mac}"
        }
    done

    # 3) Disk serials
    for prefix in scsi sata virtio ide; do
        for i in $(seq 0 7); do
            local diskline=$(conf_get "$vmid" "${prefix}${i}")
            [[ -z "$diskline" ]] && continue
            local ns=$(rand_serial 20)
            local cleaned=$(echo "$diskline" | sed 's/,serial=[^,]*//' | sed 's/serial=[^,]*//')
            conf_set "$vmid" "${prefix}${i}" "${cleaned},serial=${ns}"
            print_ok "${prefix}${i}: serial=${ns}"
        done
    done

    # 4) QEMU args
    local bios_ver="$(( RANDOM % 5 + 1 )).$(( RANDOM % 30 ))"
    local bios_date="$(( RANDOM % 12 + 1 ))/$(( RANDOM % 28 + 1 ))/$(( RANDOM % 4 + 2021 ))"
    local board_serial=$(rand_serial 12)
    local chassis_serial=$(rand_serial 12)
    local all_args="-smbios type=0,vendor=American Megatrends Inc.,version=${bios_ver},date=${bios_date}"
    all_args="${all_args} -smbios type=2,manufacturer=${mfr},product=${prod},serial=${board_serial}"
    all_args="${all_args} -smbios type=3,manufacturer=Default string,serial=${chassis_serial}"
    conf_set "$vmid" "args" "$all_args"
    print_ok "QEMU args set"

    echo ""
    print_ok "All fingerprints randomized for VM ${vmid}!"
    print_warn "Restart the VM for changes to take effect."
    log_action "VM${vmid} FULL RANDOMIZATION"
}

# ============================================================================
# BATCH RANDOMIZE (multiple VMs)
# ============================================================================

batch_randomize() {
    print_banner
    echo -e "  ${RED}BATCH RANDOMIZE — Multiple VMs${RESET}"
    print_sep
    echo ""

    local vmids=()
    for conf in "${PVE_CONF_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        vmids+=($(basename "$conf" .conf))
    done

    echo "  Available VMIDs: ${vmids[*]}"
    echo ""
    read -rp "  Enter VMIDs (space-separated, or 'ALL'): " input

    local targets=()
    if [[ "$input" == "ALL" ]]; then
        targets=("${vmids[@]}")
    else
        IFS=' ' read -ra targets <<< "$input"
    fi

    echo ""
    read -rp "  Randomize ${#targets[@]} VMs? Type 'YES': " confirm
    [[ "$confirm" != "YES" ]] && { print_warn "Cancelled."; return; }

    for vmid in "${targets[@]}"; do
        if conf_exists "$vmid"; then
            echo ""
            echo -e "  ${CYAN}━━━ VM ${vmid} ━━━${RESET}"
            randomize_all "$vmid"
        else
            print_err "VM ${vmid} config not found, skipping."
        fi
    done
}

# ============================================================================
# MAIN MENU
# ============================================================================

vm_menu() {
    local vmid=$1
    while true; do
        print_banner
        echo -e "  ${MAGENTA}VM ${vmid} MENU${RESET}"
        print_sep
        echo ""
        echo -e "    ${CYAN}[1]${RESET}  View Current Fingerprint"
        echo ""
        echo -e "    ${YELLOW}[2]${RESET}  Edit SMBIOS (UUID/Manufacturer/Serial)"
        echo -e "    ${YELLOW}[3]${RESET}  Edit MAC Address"
        echo -e "    ${YELLOW}[4]${RESET}  Edit Disk Serial Number"
        echo -e "    ${YELLOW}[5]${RESET}  Edit QEMU Args (BIOS/Board/Chassis)"
        echo ""
        echo -e "    ${RED}[R]${RESET}  Randomize ALL Fingerprints"
        echo -e "    ${GREEN}[B]${RESET}  Backup Config"
        echo -e "    ${GRAY}[0]${RESET}  Back to VM list"
        echo ""
        print_sep
        echo ""
        read -rp "  Select: " choice

        case "$choice" in
            1) view_fingerprint "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            2) edit_smbios "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            3) edit_mac "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            4) edit_disk_serial "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            5) edit_qemu_args "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            R|r) randomize_all "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            B|b) backup_conf "$vmid"; echo ""; read -rp "  Press Enter..." ;;
            0) return ;;
            *) print_err "Invalid option." ; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        print_banner
        echo -e "  ${MAGENTA}MAIN MENU${RESET}"
        print_sep
        echo ""
        echo -e "    ${CYAN}[1]${RESET}  List VMs"
        echo -e "    ${CYAN}[2]${RESET}  Select VM by ID"
        echo -e "    ${RED}[3]${RESET}  Batch Randomize Multiple VMs"
        echo -e "    ${GRAY}[0]${RESET}  Exit"
        echo ""
        print_sep
        echo ""
        read -rp "  Select: " choice

        case "$choice" in
            1) list_vms; read -rp "  Press Enter..." ;;
            2)
                read -rp "  Enter VMID: " vmid
                if conf_exists "$vmid"; then
                    vm_menu "$vmid"
                else
                    print_err "VM ${vmid} config not found."
                    sleep 2
                fi
                ;;
            3) batch_randomize; echo ""; read -rp "  Press Enter..." ;;
            0) echo -e "\n  ${CYAN}Goodbye!${RESET}\n"; exit 0 ;;
            *) print_err "Invalid option." ; sleep 1 ;;
        esac
    done
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}  ERROR: Must run as root on PVE host.${RESET}"
    exit 1
fi

# Check PVE
if [[ ! -d "$PVE_CONF_DIR" ]]; then
    echo -e "${RED}  ERROR: PVE config dir not found: ${PVE_CONF_DIR}${RESET}"
    echo -e "${YELLOW}  Make sure this script runs on the Proxmox VE host.${RESET}"
    exit 1
fi

# Direct VMID argument
if [[ -n "${1:-}" ]]; then
    if conf_exists "$1"; then
        vm_menu "$1"
    else
        echo -e "${RED}  VM $1 not found.${RESET}"
        exit 1
    fi
else
    main_menu
fi
