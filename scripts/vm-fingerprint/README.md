# PVE VM 硬件指纹修改器 (PVE VM Hardware Fingerprint Editor)

这是一个用于查看、编辑和随机化 Proxmox VE (PVE) 虚拟机硬件标识符（指纹）的 Bash 脚本。它通过直接修改虚拟机配置文件（`/etc/pve/qemu-server/<vmid>.conf`）来欺骗硬件数据，使虚拟机看起来像典型的消费级裸金属硬件。

## 功能特性 (Features)

- **查看指纹 (View Fingerprints)**：检查任何虚拟机的当前 SMBIOS、MAC 地址、磁盘序列号和 QEMU 参数。
- **编辑 SMBIOS (Edit SMBIOS)**：手动编辑或根据真实的硬件预设（如 Dell、Lenovo、HP、ASUS、Gigabyte、MSI、Acer 等）自动随机化 SMBIOS 字段（UUID、制造商、产品、序列号、SKU、系列）。
- **编辑 MAC 地址 (Edit MAC Addresses)**：随机化或手动设置任何已配置网络接口（`net0` - `net7`）的 MAC 地址。
- **编辑磁盘序列号 (Edit Disk Serials)**：随机化或手动设置附加磁盘（`scsi`、`sata`、`virtio`、`ide`）的序列号。
- **高级 QEMU 参数 (Advanced QEMU Args)**：注入高级 SMBIOS 类型（类型 0：BIOS，类型 2：主板，类型 3：机箱）以进一步伪装虚拟机。
- **全部随机化 (Randomize All)**：一键式选项，可完全随机化虚拟机的 SMBIOS、MAC 地址、磁盘序列号和 QEMU 参数。
- **批量随机化 (Batch Randomize)**：一次性随机化多个虚拟机。
- **自动备份 (Automatic Backups)**：在应用完全随机化之前，会自动创建虚拟机配置文件的备份。

## 系统要求 (Requirements)

- Proxmox VE (PVE) 主机。
- Root 权限（脚本需要修改 `/etc/pve/qemu-server/` 目录）。
- `python3`（可选，用作 UUID 生成的后备方案）。
- `xxd`（通常在 Debian/PVE 上默认安装，用于生成十六进制数据）。

## 使用指南 (Usage)

1. 将脚本 `pve-fingerprint.sh` 传输到您的 Proxmox VE 主机上。
2. 赋予脚本执行权限：
   ```bash
   chmod +x pve-fingerprint.sh
   ```
3. 以 root 身份运行脚本。您可以启动交互式菜单，也可以直接传递虚拟机 ID (VMID)：
   ```bash
   # 启动主交互式菜单
   ./pve-fingerprint.sh

   # 或者直接进入特定虚拟机的菜单
   ./pve-fingerprint.sh 100
   ```

### 日志与备份 (Logs & Backups)

- **活动日志 (Activity Logs)**：所有的修改和更改都会被记录到 `/root/vm-fingerprint.log` 文件中。
- **配置备份 (Config Backups)**：虚拟机配置的备份会保存到 `/root/vm-fingerprint-backups/` 目录下。您可以从虚拟机菜单中手动触发备份，并且在运行完全随机化之前也会自动创建备份。

## 免责声明 (Disclaimer)

此工具直接编辑核心的 Proxmox VE 配置文件。建议在进行重大更改之前确保虚拟机已停止运行，或者在编辑完毕后重启虚拟机以使新的指纹生效。请务必核实您的配置并保留备份。
