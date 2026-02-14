#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${1:-vmbr_sbx}"
IFACES_SNIPPET="/etc/network/interfaces.d/${BRIDGE}.cfg"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need ip

bridge_exists() {
  ip link show "$BRIDGE" >/dev/null 2>&1
}

ensure_bridge_config_present() {
  if [[ -f "$IFACES_SNIPPET" ]]; then
    return 0
  fi

  cat > "$IFACES_SNIPPET" <<EOF
auto ${BRIDGE}
iface ${BRIDGE} inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
EOF
}

bring_bridge_up() {
  # Prefer ifreload2 if present (PVE default), otherwise ifup.
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
  else
    ifup "$BRIDGE" || true
  fi
}

main() {
  if bridge_exists; then
    echo "Bridge ${BRIDGE} already exists."
    exit 0
  fi

  echo "Bridge ${BRIDGE} missing; creating config ${IFACES_SNIPPET} ..."
  ensure_bridge_config_present

  echo "Applying network config..."
  bring_bridge_up

  if bridge_exists; then
    echo "Bridge ${BRIDGE} is up."
  else
    echo "Failed to bring up ${BRIDGE}. Check /etc/network/interfaces and systemctl status networking." >&2
    exit 1
  fi
}

main "$@"
