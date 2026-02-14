#!/usr/bin/env bash
set -euo pipefail

VMID="${1:?Usage: $0 <vmid>}"

IN_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-live-server-amd64.iso"
OUT_ISO="/var/lib/vz/template/iso/ubuntu-24.04.4-autoinstall-serial-${VMID}.iso"

HOSTNAME="sandbox"
USERNAME="ubuntu"
PASSWORD_PLAIN="rootme"
SSH_PUBKEY=$(cat ~/.ssh/id_ed25519.pub) # this copies your local ssh public key to the host

ISO_STORAGE_ID="${ISO_STORAGE_ID:-local}"
DISK_STORAGE_ID="${DISK_STORAGE_ID:-local-lvm}"
DISK_SIZE_GB="${DISK_SIZE_GB:-16}"

BRIDGE_SBX="${BRIDGE_SBX:-vmbr_sbx}"

MEMORY_MB="${MEMORY_MB:-2048}"
CORES="${CORES:-2}"
CPU_TYPE="${CPU_TYPE:-x86-64-v2-AES}"
MACHINE_TYPE="${MACHINE_TYPE:-q35}"
BIOS_TYPE="${BIOS_TYPE:-seabios}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

need qm
need xorriso
need openssl
need sed
need awk
need ip

if command -v 7zz >/dev/null 2>&1; then
  UNZIP=7zz
elif command -v 7z >/dev/null 2>&1; then
  UNZIP=7z
else
  echo "Missing 7zz/7z (install: 7zip or p7zip-full)" >&2
  exit 1
fi

[[ -f "$IN_ISO" ]] || { echo "Missing ISO: $IN_ISO" >&2; exit 1; }

ensure_bridge() {
  local br="$1"
  local cfg="/etc/network/interfaces.d/${br}.cfg"

  if ip link show "$br" >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p /etc/network/interfaces.d
  if [[ ! -f "$cfg" ]]; then
    cat > "$cfg" <<EOF
auto ${br}
iface ${br} inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
EOF
  fi

  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
  else
    ifup "$br" || true
  fi

  ip link show "$br" >/dev/null 2>&1
}

create_vm_if_missing() {
  if qm status "$VMID" >/dev/null 2>&1; then
    return 0
  fi

  qm create "$VMID" \
    --name "${HOSTNAME}" \
    --memory "${MEMORY_MB}" \
    --cores "${CORES}" \
    --cpu "${CPU_TYPE}" \
    --machine "${MACHINE_TYPE}" \
    --bios "${BIOS_TYPE}"

  qm set "$VMID" --scsihw 'virtio-scsi-pci'
  qm set "$VMID" --serial0 'socket'
  qm set "$VMID" --vga 'serial0'
  qm set "$VMID" --net0 "virtio,bridge=${BRIDGE_SBX}"
  qm set "$VMID" --scsi0 "${DISK_STORAGE_ID}:${DISK_SIZE_GB}"
}

extract_iso() {
  local iso="$1"
  local outdir="$2"
  mkdir -p "$outdir"
  "$UNZIP" x "$iso" "-o${outdir}" >/dev/null
}

patch_grub_linux_lines() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  awk '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    /^[ \t]*linux[ \t]+/ {
      n=split($0, a, /[ \t]+/)
      linux=a[1]
      kernel=a[2]

      args=""
      for (i=3; i<=n; i++) {
        tok=a[i]
        if (tok == "---") continue
        if (tok ~ /^autoinstall$/) continue
        if (tok ~ /^ds=nocloud/) continue
        if (tok ~ /^console=/) continue
        args = args " " tok
      }
      args=trim(args)

      wanted="console=ttyS0,115200n8,keep console=tty0 autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---"
      if (args != "") print linux "\t" kernel " " args " " wanted
      else print linux "\t" kernel " " wanted
      next
    }
    { print }
  ' "$f" > "${f}.new" && mv "${f}.new" "$f"
}

write_nocloud_seed() {
  local dir="$1"
  local pw_hash="$2"

  mkdir -p "$dir/nocloud"

  cat > "$dir/nocloud/meta-data" <<EOF
instance-id: ${HOSTNAME}-${VMID}
local-hostname: ${HOSTNAME}
EOF

  cat > "$dir/nocloud/user-data" <<EOF
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
    password: "${pw_hash}"
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
    - curtin in-target --target=/target bash -lc "sed -i -E 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8,keep console=tty0\"/' /etc/default/grub"
    - curtin in-target --target=/target bash -lc "grep -q '^GRUB_TERMINAL=' /etc/default/grub && sed -i -E 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=serial/' /etc/default/grub || echo 'GRUB_TERMINAL=serial' >> /etc/default/grub"
    - curtin in-target --target=/target bash -lc "grep -q '^GRUB_SERIAL_COMMAND=' /etc/default/grub && sed -i -E 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"/' /etc/default/grub || echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"' >> /etc/default/grub"
    - curtin in-target --target=/target update-grub
EOF
}

iso_selfcheck() {
  local iso="$1"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  xorriso -osirrox on -indev "$iso" -extract /boot/grub/grub.cfg "$tmp/grub.cfg" >/dev/null 2>&1 || {
    echo "Selfcheck failed: cannot extract grub.cfg from $iso" >&2
    return 1
  }

  local line
  line="$(grep -nE '^[[:space:]]*linux[[:space:]]+/casper/vmlinuz' "$tmp/grub.cfg" | head -n 1 || true)"
  [[ -n "$line" ]] || { echo "Selfcheck failed: no vmlinuz linux line found" >&2; return 1; }

  echo "$line" | grep -q 'console=ttyS0,115200n8,keep' || { echo "Selfcheck failed: missing serial console" >&2; echo "$line" >&2; return 1; }
  echo "$line" | grep -q 'autoinstall' || { echo "Selfcheck failed: missing autoinstall" >&2; echo "$line" >&2; return 1; }
  echo "$line" | grep -q 'ds=nocloud' || { echo "Selfcheck failed: missing ds=nocloud" >&2; echo "$line" >&2; return 1; }
  echo "$line" | grep -q '/cdrom/nocloud/' || { echo "Selfcheck failed: missing /cdrom/nocloud/" >&2; echo "$line" >&2; return 1; }
  echo "$line" | grep -q ' ---' || { echo "Selfcheck failed: missing --- terminator" >&2; echo "$line" >&2; return 1; }
}

build_custom_iso() {
  local in_iso="$1"
  local out_iso="$2"

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  extract_iso "$in_iso" "$workdir/iso"

  local pw_hash
  pw_hash="$(openssl passwd -6 "${PASSWORD_PLAIN}")"

  write_nocloud_seed "$workdir/iso" "$pw_hash"

  patch_grub_linux_lines "$workdir/iso/boot/grub/grub.cfg"
  patch_grub_linux_lines "$workdir/iso/boot/grub/loopback.cfg"

  [[ -e "$workdir/iso/[BOOT]/1-Boot-NoEmul.img" && -e "$workdir/iso/[BOOT]/2-Boot-NoEmul.img" ]] || {
    echo "Missing [BOOT] images in extracted ISO; cannot rebuild with this method." >&2
    exit 1
  }

  xorriso -as mkisofs \
    -r -V "UBUNTU-AUTOINSTALL" \
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

  iso_selfcheck "$out_iso"
}

ensure_bridge "$BRIDGE_SBX" || { echo "Failed to create bridge $BRIDGE_SBX" >&2; exit 1; }
create_vm_if_missing

if [[ -f "$OUT_ISO" ]]; then
  echo "OUT_ISO already exists: $OUT_ISO"
  read -r -p "Rebuild it now? [y/N] " ans
  case "${ans:-N}" in
    y|Y|yes|YES) rm -f "$OUT_ISO" ;;
    *) : ;;
  esac
fi

if [[ ! -f "$OUT_ISO" ]]; then
  build_custom_iso "$IN_ISO" "$OUT_ISO"
fi

qm set "$VMID" --ide2 "${ISO_STORAGE_ID}:iso/$(basename "$OUT_ISO"),media=cdrom"
qm set "$VMID" --boot 'order=ide2;scsi0'
qm set "$VMID" --serial0 socket
qm set "$VMID" --vga serial0

qm start "$VMID"
echo "qm terminal $VMID"
