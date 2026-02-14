#!/usr/bin/env bash
set -euo pipefail

VMID="${1:?Usage: $0 <vmid>}"
CONF="/etc/pve/qemu-server/${VMID}.conf"

if [[ ! -f "$CONF" ]]; then
  echo "Config not found: $CONF" >&2
  exit 1
fi

# Output script to stdout
echo "#!/usr/bin/env bash"
echo "set -euo pipefail"
echo
echo "VMID=${VMID}"
echo
echo "# NOTE:"
echo "# - This recreates Proxmox hardware config only."
echo "# - Guest OS config (pfSense /etc/ttys, VPN, rules) must be restored separately."
echo
echo "qm create \$VMID \\"
echo "  --name \"$(awk -F': ' '$1=="name"{print $2}' "$CONF" | sed 's/"/\\"/g')\" \\"
echo "  --memory \"$(awk -F': ' '$1=="memory"{print $2}' "$CONF")\" \\"
echo "  --cores \"$(awk -F': ' '$1=="cores"{print $2}' "$CONF")\" \\"
echo "  --cpu \"$(awk -F': ' '$1=="cpu"{print $2}' "$CONF")\" \\"
echo "  --machine \"$(awk -F': ' '$1=="machine"{print $2}' "$CONF")\" \\"
echo "  --bios \"$(awk -F': ' '$1=="bios"{print $2}' "$CONF")\""

# Keys we will emit as qm set after create
emit_set_key() {
  local key="$1"
  local val
  val="$(awk -F': ' -v k="$key" '$1==k{print $2}' "$CONF" || true)"
  if [[ -n "${val}" ]]; then
    echo "qm set \$VMID --${key} '${val}'"
  fi
}

echo
emit_set_key "boot"
emit_set_key "scsihw"
emit_set_key "vga"

# serial ports
for i in 0 1 2 3; do
  val="$(awk -F': ' -v k="serial${i}" '$1==k{print $2}' "$CONF" || true)"
  if [[ -n "${val}" ]]; then
    echo "qm set \$VMID --serial${i} '${val}'"
  fi
done

# net devices
for i in $(awk -F': ' '$1 ~ /^net[0-9]+$/{print $1}' "$CONF" | sed 's/net//' | sort -n); do
  val="$(awk -F': ' -v k="net${i}" '$1==k{print $2}' "$CONF")"
  echo "qm set \$VMID --net${i} '${val}'"
done

# disk-ish devices (scsi*, sata*, ide*, virtio*)
for k in $(awk -F': ' '$1 ~ /^(scsi|sata|ide|virtio)[0-9]+$/{print $1}' "$CONF" | sort); do
  val="$(awk -F': ' -v kk="$k" '$1==kk{print $2}' "$CONF")"
  echo "qm set \$VMID --${k} '${val}'"
done

# efidisk if present
emit_set_key "efidisk0"

echo
echo "# Start VM"
echo "qm start \$VMID"
