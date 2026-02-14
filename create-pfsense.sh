#!/usr/bin/env bash
set -euo pipefail

VMID=9000

./create-bridge.sh vmbr_sbx


# NOTE:
# - This recreates Proxmox hardware config only.
# - Guest OS config (pfSense /etc/ttys, VPN, rules) must be restored separately.

qm create $VMID \
  --name "tmpl-egress-pfsense" \
  --memory "4096" \
  --cores "2" \
  --cpu "x86-64-v2-AES" \
  --machine "q35" \
  --bios "seabios"

qm set $VMID --boot 'order=scsi0;ide2'
qm set $VMID --scsihw 'virtio-scsi-pci'
qm set $VMID --vga 'none'
qm set $VMID --serial0 'socket'
qm set $VMID --net0 'virtio=BC:24:11:D6:E1:56,bridge=vmbr0'
qm set $VMID --net1 'virtio=BC:24:11:D5:62:1B,bridge=vmbr_sbx'
qm set $VMID --ide2 'local:iso/pfSense-CE.iso,media=cdrom,size=998840K'
qm set $VMID --scsi0 'local-lvm:vm-9000-disk-1,size=16G'

# Start VM
qm start $VMID
