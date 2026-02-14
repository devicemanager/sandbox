#!/usr/bin/env bash
set -euo pipefail

VMID="${1:?Usage: $0 <vmid>}"

IN_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-live-server-amd64.iso"
OUT_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-autoinstall-serial-${VMID}.iso"

HOSTNAME="sandbox"
USERNAME="ubuntu"
PASSWORD_PLAIN="rootme"

# Replace with the FULL key line:
SSH_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHhb3RmQCDv7ENLS7QrmHWRc9bsMD++z6QbEtun/J62O'

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need qm
need 7z
need xorriso
need openssl
need sed
need awk

if [[ ! -f "$IN_ISO" ]]; then
  echo "Ubuntu ISO not found at: $IN_ISO" >&2
  exit 1
fi

# Packages (best-effort)
if ! command -v 7z >/dev/null 2>&1 || ! command -v xorriso >/dev/null 2>&1; then
  apt-get update
  apt-get install -y p7zip-full xorriso
fi

# Generate SHA-512 crypt hash for autoinstall identity.password
PW_HASH="$(openssl passwd -6 "${PASSWORD_PLAIN}")"

build_custom_iso() {
  local in_iso="$1"
  local out_iso="$2"

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  echo "Extracting ISO..."
  7z x "$in_iso" -o"$workdir/iso" >/dev/null

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
    sed -i -E "s@^(\\s*linux\\s+[^ ]+)\\s*(.*)@\\1 \\2 ${ds} ${con}@g" "$f"
  done

  echo "Rebuilding ISO: $out_iso"
  # This relies on Ubuntu ISO extraction containing [BOOT] images (common with 7z).
  if [[ ! -e "$workdir/iso/[BOOT]/1-Boot-NoEmul.img" ]]; then
    echo "ERROR: Extracted ISO does not contain [BOOT] images; ISO rebuild command needs adjustment." >&2
    echo "Try: apt install -y xorriso; use xorriso -indev to extract instead of 7z." >&2
    exit 1
  fi

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

build_custom_iso "$IN_ISO" "$OUT_ISO"

echo "Attaching ISO to VM $VMID and configuring serial..."
qm set "$VMID" --ide2 "local:iso/$(basename "$OUT_ISO"),media=cdrom"
qm set "$VMID" --boot 'order=ide2;scsi0'
qm set "$VMID" --serial0 socket
qm set "$VMID" --vga serial0

echo "Done. Start the VM:"
echo "  qm start $VMID"
echo "Follow install via:"
echo "  qm terminal $VMID"
