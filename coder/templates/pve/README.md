---
display_name: Proxmox VM
description: Provision VMs on Proxmox VE as Coder workspaces
icon: ../../../../.icons/proxmox.svg
verified: false
tags: [proxmox, vm, cloud-init, qemu]
---

# Proxmox VM Template for Coder

Provision Linux VMs on Proxmox as [Coder workspaces](https://coder.com/docs/workspaces). The template clones a cloud‑init base image, injects user‑data via Snippets, and runs the Coder agent under the workspace owner's Linux user.

## Prerequisites

- Proxmox VE 8/9
- Proxmox API token with access to nodes and storages
- SSH access from Coder provisioner to Proxmox VE
- Storage with "Snippets" content enabled
- Ubuntu cloud‑init image/template on Proxmox
  - Latest images: https://cloud-images.ubuntu.com/ ([source](https://cloud-images.ubuntu.com/))

## Prepare a Proxmox Cloud‑Init Template (once)

Run on the Proxmox node. This uses a RELEASE variable so you always pull a current image.

```bash
# Choose a release (e.g., jammy or noble)
RELEASE=jammy
IMG_URL="https://cloud-images.ubuntu.com/${RELEASE}/current/${RELEASE}-server-cloudimg-amd64.img"
IMG_PATH="/mnt/nfs/zfs/template/iso/${RELEASE}-server-cloudimg-amd64.img"

# Download cloud image
wget "$IMG_URL" -O "$IMG_PATH"

# Create base VM (example ID 9511), enable QGA, correct boot order
NAME="ubuntu-${RELEASE}-cloudinit"
qm create 9511 --name "$NAME" --memory 4096 --cores 2 \
  --net0 virtio,bridge=vmbr40,tag=30 --agent enabled=1
qm set 9511 --scsihw virtio-scsi-pci
qm importdisk 9511 "$IMG_PATH" cd6
qm set 9511 --scsi0 cd6:9511/vm-9511-disk-0.raw
qm set 9511 --ide2 cloud:cloudinit
qm set 9511 --serial0 socket --vga serial0
qm set 9511 --boot 'order=scsi0;ide2;net0'


# Convert to template
qm template 9511
```

Verify:

```bash
qm config 9511 | grep -E 'template:|agent:|boot:|ide2:|scsi0:'
```

### Enable Snippets via GUI

- Datacenter → Storage → select `local` → Edit → Content → check "Snippets" → OK
- Ensure `/var/lib/vz/snippets/` exists on the node for snippet files
- Template page → Cloud‑Init → Snippet Storage: `local` → File: your yml → Apply

## Configure this template

Edit `terraform.tfvars` with your environment:

```hcl
# Proxmox API
proxmox_api_url          = "https://<PVE_HOST>:8006/api2/json"
proxmox_api_token_id     = "<USER@REALM>!<TOKEN>"
proxmox_api_token_secret = "<SECRET>"

# SSH to the node (for snippet upload)
proxmox_host     = "<PVE_HOST>"
proxmox_password = "<NODE_ROOT_OR_SUDO_PASSWORD>"
proxmox_ssh_user = "root"

# Infra defaults
proxmox_node        = "pve"
disk_storage        = "local-lvm"
snippet_storage     = "local"
bridge              = "vmbr0"
vlan                = 0
clone_template_vmid = 999
```

### Variables (terraform.tfvars)

- These values are standard Terraform variables that the template reads at apply time.
- Place secrets (e.g., `proxmox_api_token_secret`, `proxmox_password`) in `terraform.tfvars` or inject with environment variables using `TF_VAR_*` (e.g., `TF_VAR_proxmox_api_token_secret`).
- You can also override with `-var`/`-var-file` if you run Terraform directly. With Coder, the repo's `terraform.tfvars` is bundled when pushing the template.

Variables expected:

- `proxmox_api_url`, `proxmox_api_token_id`, `proxmox_api_token_secret` (sensitive)
- `proxmox_host`, `proxmox_password` (sensitive), `proxmox_ssh_user`
- `proxmox_node`, `disk_storage`, `snippet_storage`, `bridge`, `vlan`, `clone_template_vmid`
- Coder parameters: `cpu_cores`, `memory_mb`, `disk_size_gb`

## Proxmox API Token (GUI/CLI)

Docs: https://pve.proxmox.com/wiki/User_Management#pveum_tokens

GUI:

1. (Optional) Create automation user: Datacenter → Permissions → Users → Add (e.g., `terraform@pve`)
2. Permissions: Datacenter → Permissions → Add → User Permission
   - Path: `/` (or narrower covering your nodes/storages)
   - Role: `PVEVMAdmin` + `PVEStorageAdmin` (or `PVEAdmin` for simplicity)
3. Token: Datacenter → Permissions → API Tokens → Add → copy Token ID and Secret
4. Test:

```bash
curl -k -H "Authorization: PVEAPIToken=<USER@REALM>!<TOKEN>=<SECRET>" \
  https:// < PVE_HOST > :8006/api2/json/version
```

CLI:

```bash
pveum user add terraform@pve --comment 'Terraform automation user'
pveum aclmod / -user terraform@pve -role PVEAdmin
pveum user token add terraform@pve terraform --privsep 0
```

## Use

```bash
# From this directory
coder templates push --yes proxmox-cloudinit --directory . | cat
```

Create a workspace from the template in the Coder UI. First boot usually takes 60–120s while cloud‑init runs.

## How it works

- Uploads rendered cloud‑init user‑data to `<storage>:snippets/<vm>.yml` via the provider's `proxmox_virtual_environment_file`
- VM config: `virtio-scsi-pci`, boot order `scsi0, ide2, net0`, QGA enabled
- Linux user equals Coder workspace owner (sanitized). To avoid collisions, reserved names (`admin`, `root`, etc.) get a suffix (e.g., `admin1`). User is created with `primary_group: adm`, `groups: [sudo]`, `no_user_group: true`
- systemd service runs as that user:
  - `coder-agent.service`

## Troubleshooting quick hits

- iPXE boot loop: ensure template has bootable root disk and boot order `scsi0,ide2,net0`
- QGA not responding: install/enable QGA in template; allow 60–120s on first boot
- Snippet upload errors: storage must include `Snippets`; token needs Datastore permissions; path format `<storage>:snippets/<file>` handled by provider
- Permissions errors: ensure the token's role covers the target node(s) and storages
- Verify snippet/QGA: `qm config <vmid> | egrep 'cicustom|ide2|ciuser'`

## References

- Ubuntu Cloud Images (latest): https://cloud-images.ubuntu.com/ ([source](https://cloud-images.ubuntu.com/))
- Proxmox qm(1) manual: https://pve.proxmox.com/pve-docs/qm.1.html
- Proxmox Cloud‑Init Support: https://pve.proxmox.com/wiki/Cloud-Init_Support
- Terraform Proxmox provider (bpg): `bpg/proxmox` on the Terraform Registry
- Coder – Best practices & templates:
  - https://coder.com/docs/tutorials/best-practices/speed-up-templates
  - https://coder.com/docs/tutorials/template-from-scratch
