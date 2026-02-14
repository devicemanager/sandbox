#!/usr/bin/env bash
set -euo pipefail

# Unattended Ubuntu Server 24.04.x installer ISO builder + VM attach helper for Proxmox VE
#
# What it does:
#  - Builds a custom Ubuntu live-server ISO that autoinstalls using Subiquity autoinstall (NoCloud)
#  - Sets English locale, Norwegian keyboard (Mac variant), UTC timezone
#  - Uses LVM layout on the whole disk
#  - Installs OpenSSH server, enables password auth, adds your SSH authorized key
#  - Forces serial console during install and after install; enables serial-getty on ttyS0
#  - Attaches the generated ISO to an existing VMID and sets serial console options
#
# Requirements on PVE node:
#  - packages: xorriso, 7zip, openssl, sed, gawk (or any awk)
#
# Usage:
#  1) Create the VM first (disk + net + etc). Example:
#       qm create 9010 --name sandbox --memory 2048 --cores 2 --machine q35 --bios seabios
#       qm set 9010 --scsihw virtio-scsi-pci --scsi0 local-lvm:16
#       qm set 9010 --net0 virtio,bridge=vmbr_sbx
#  2) Run this script:
#       ./ubuntu-unattended.sh 9010
#  3) Boot and watch:
#       qm start 9010
#       qm terminal 9010

VMID="${1:?Usage: $0 <vmid>}"

# --- Inputs you said you want ---
IN_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-live-server-amd64.iso"
OUT_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-autoinstall-serial-${VMID}.iso"

HOSTNAME="sandbox"
USERNAME="ubuntu"
PASSWORD_PLAIN="rootme"

# You pasted a truncated key in chat; you MUST replace this with the full one-line public key.
SSH_PUBKEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC5PLGNnx4d5fDA03tpeFaRREPLACE_WITH_FULL_KEY comment'

# Proxmox storage where ISOs are available as "local:iso/<name>.iso"
ISO_STORAGE_ID="${ISO_STORAGE_ID:-local}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

need qm
need xorriso
need 7z 
need openssl
need sed
need awk

if [[ ! -f "$IN_ISO" ]]; then
  echo "Input ISO not found: $IN_ISO" >&2
  exit 1
fi

if ! qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID does not exist. Create the VM first, then rerun." >&2
  exit 1
fi

# Generate SHA-512 crypt hash for autoinstall identity.password
PW_HASH="$(openssl passwd -6 "${PASSWORD_PLAIN}")"

_extract_iso() {
  local iso="$1"
  local outdir="$2"

  mkdir -p "$outdir"

  # Prefer 7zz (Debian trixie package "7zip" provides 7zz)
  if command -v 7zz >/dev/null 2>&1; then
    7zz x "$iso" "-o${outdir}" >/dev/null
  else
    7z x "$iso" "-o${outdir}" >/dev/null
  fi
}

_build_custom_iso() {
  local in_iso="$1"
  local out_iso="$2"

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  echo "Extracting ISO..."
  _extract_iso "$in_iso" "$workdir/iso"

  echo "Writing NoCloud seed..."
  mkdir -p "$workdir/iso/nocloud"

  cat > "$workdir/iso/nocloud/meta-data" <<EOF
instance-id: ${HOSTNAME}-${VMID}
local-hostname: ${HOSTNAME}
EOF

  cat > "$workdir/iso/nocloud/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8
  timezone: Etc/UTC

  keyboard:
    layout: "no"
    variant: "mac"

  identity:
    hostname: ${HOSTNAME}
    username: ${USERNAME}
    password: "${PW_HASH}"

  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - "${SSH_PUBKEY}"

  storage:
    layout:
      name: lvm

  late-commands:
    - curtin in-target --target=/target systemctl enable serial-getty@ttyS0.service
    - curtin in-target --target=/target bash -lc 'sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\\"console=ttyS0,115200n8 console=tty0\\"/" /etc/default/grub'
    - curtin in-target --target=/target bash -lc 'grep -q "^GRUB_TERMINAL" /etc/default/grub || echo "GRUB_TERMINAL=serial" >> /etc/default/grub'
    - curtin in-target --target=/target bash -lc 'grep -q "^GRUB_SERIAL_COMMAND" /etc/default/grub || echo "GRUB_SERIAL_COMMAND=\\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\\"" >> /etc/default/grub'
    - curtin in-target --target=/target update-grub
EOF

  echo "Patching GRUB to force autoinstall + serial console..."
  local ds="autoinstall ds=nocloud\\;s=/cdrom/nocloud/"
  local con="console=ttyS0,115200n8"

  for f in "$workdir/iso/boot/grub/grub.cfg" "$workdir/iso/boot/grub/loopback.cfg"; do
    [[ -f "$f" ]] || continue
    # Append parameters to every "linux ..." line.
    sed -i -E "s@^(\\s*linux\\s+[^ ]+)\\s*(.*)@\\1 \\2 ${ds} ${con}@g" "$f"
  done

  # Sanity check: extraction should include [BOOT] blobs (typical with 7z extraction of Ubuntu ISOs)
  if [[ ! -e "$workdir/iso/[BOOT]/1-Boot-NoEmul.img" || ! -e "$workdir/iso/[BOOT]/2-Boot-NoEmul.img" ]]; then
    echo "ERROR: Extracted ISO does not contain [BOOT] images." >&2
    echo "This script currently relies on 7z/7zz extraction producing [BOOT]/* images." >&2
    echo "Workaround: I can provide an alternate xorriso-based extraction/repack method if needed." >&2
    exit 1
  fi

  echo "Rebuilding ISO: $out_iso"
  xorriso -as mkisofs \
    -r -V "Ubuntu-Server-Autoinstall" \
    -o "$out_iso" \
    -J -joliet-long -l \
    -isohybrid-mbr "$workdir/iso/[BOOT]/1-Boot-NoEmul.img" \
    -partition_offset 16 \
    -append_partition 2 0xef "$workdir/iso/[BOOT]/2-Boot-NoEmul.img" \
    -appended_part_as_gpt \
    -c boot.catalog \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:all::' \
    -no-emul-boot \
    "$workdir/iso" >/dev/null
}

# Build ISO if missing or older than input ISO
if [[ ! -f "$OUT_ISO" || "$OUT_ISO" -ot "$IN_ISO" ]]; then
  _build_custom_iso "$IN_ISO" "$OUT_ISO"
else
  echo "Custom ISO already exists and is up-to-date: $OUT_ISO"
fi

# Attach ISO to VM and configure serial
echo "Attaching ISO to VM $VMID and configuring serial..."
qm set "$VMID" --ide2 "${ISO_STORAGE_ID}:iso/$(basename "$OUT_ISO"),media=cdrom"
qm set "$VMID" --boot 'order=ide2;scsi0'
qm set "$VMID" --serial0 socket
qm set "$VMID" --vga serial0

cat <<EOF

Done.

Next:
  qm start ${VMID}
  qm terminal ${VMID}

Notes:
- Replace SSH_PUBKEY in this script with your FULL one-line key (your chat paste was truncated).
- After install completes and reboots, you may want:
    qm set ${VMID} --boot 'order=scsi0;ide2'
    qm set ${VMID} --ide2 none
EOF
