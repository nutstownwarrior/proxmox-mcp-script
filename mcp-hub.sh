#!/usr/bin/env bash
# mcp-hub.sh — MCP Hub LXC Container Provisioner
# Run this script on the Proxmox HOST shell.
# It creates a Debian 12 unprivileged LXC container and bootstraps it with
# mcp-hub-install.sh pulled from GitHub.
#
# No external framework dependencies — fully self-contained.

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

msg_info()  { echo -e "  ${BLU}[•]${NC} $*"; }
msg_ok()    { echo -e "  ${GRN}[✓]${NC} $*"; }
msg_error() { echo -e "  ${RED}[✗]${NC} $*" >&2; }
msg_warn()  { echo -e "  ${YLW}[!]${NC} $*"; }

# ── Require root ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  msg_error "This script must be run as root on the Proxmox host."
  exit 1
fi

# ── Require pct ───────────────────────────────────────────────────────────────
if ! command -v pct &>/dev/null; then
  msg_error "'pct' not found. This script must run on a Proxmox VE host."
  exit 1
fi

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — LXC Container Provisioner${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYN}Debian 12 · Unprivileged · Nesting enabled${NC}"
echo -e "  ${CYN}2 CPU cores · 1 GB RAM · 8 GB disk${NC}"
echo ""

# ── Interactive prompts ────────────────────────────────────────────────────────
read -rp "  Container ID    [default: 200]:       " CT_ID
read -rp "  Hostname        [default: mcp-hub]:   " CT_HN
read -rp "  Storage         [default: local-lvm]: " STOR
read -rp "  Network bridge  [default: vmbr0]:     " BRIDGE

CT_ID="${CT_ID:-200}"
CT_HN="${CT_HN:-mcp-hub}"
STOR="${STOR:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"

echo ""
echo -e "  ${YLW}${BOLD}Configuration summary:${NC}"
echo -e "    Container ID : ${BOLD}${CT_ID}${NC}"
echo -e "    Hostname     : ${BOLD}${CT_HN}${NC}"
echo -e "    Storage      : ${BOLD}${STOR}${NC}"
echo -e "    Bridge       : ${BOLD}${BRIDGE}${NC}"
echo ""
read -rp "  Proceed? [Y/n]: " CONFIRM
if [[ "${CONFIRM,,}" == "n" ]]; then
  echo "  Aborted."
  exit 0
fi
echo ""

# ── Check container ID not already in use ─────────────────────────────────────
if pct status "${CT_ID}" &>/dev/null; then
  msg_error "Container ${CT_ID} already exists. Choose a different ID."
  exit 1
fi

# ── Find or download Debian 12 template ───────────────────────────────────────
TMPL_STORE="local"
msg_info "Checking for Debian 12 template on '${TMPL_STORE}'..."

TEMPLATE=$(pveam list "${TMPL_STORE}" 2>/dev/null \
  | awk '{print $1}' \
  | grep -E '^debian-12-standard' \
  | sort -V | tail -1 || true)

if [[ -z "${TEMPLATE}" ]]; then
  msg_info "No local template found — refreshing catalog..."
  pveam update &>/dev/null

  AVAILABLE=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep -E '^debian-12-standard' \
    | sort -V | tail -1 || true)

  if [[ -z "${AVAILABLE}" ]]; then
    msg_error "Could not locate a Debian 12 template in the Proxmox catalog."
    msg_error "Run 'pveam update' manually and check your subscription/internet."
    exit 1
  fi

  msg_info "Downloading template: ${AVAILABLE}"
  pveam download "${TMPL_STORE}" "${AVAILABLE}"

  TEMPLATE=$(pveam list "${TMPL_STORE}" 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^debian-12-standard' \
    | sort -V | tail -1)
fi

TEMPLATE_PATH="${TMPL_STORE}:vztmpl/${TEMPLATE}"
msg_ok "Template: ${TEMPLATE_PATH}"

# ── Create the LXC container ───────────────────────────────────────────────────
msg_info "Creating container ${CT_ID} (${CT_HN})..."

pct create "${CT_ID}" "${TEMPLATE_PATH}" \
  --arch amd64 \
  --ostype debian \
  --hostname "${CT_HN}" \
  --cores 2 \
  --memory 1024 \
  --swap 512 \
  --rootfs "${STOR}:8" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 0

msg_ok "Container ${CT_ID} created"

# ── Start container ────────────────────────────────────────────────────────────
msg_info "Starting container ${CT_ID}..."
pct start "${CT_ID}"
sleep 3
msg_ok "Container started"

# ── Wait for network (up to 60 s) ─────────────────────────────────────────────
msg_info "Waiting for container to reach the network..."
NETWORK_UP=0
for i in $(seq 1 30); do
  if pct exec "${CT_ID}" -- ping -c1 -W2 1.1.1.1 &>/dev/null; then
    NETWORK_UP=1
    msg_ok "Network is up (attempt ${i})"
    break
  fi
  sleep 2
done

if [[ ${NETWORK_UP} -eq 0 ]]; then
  msg_error "Timed out waiting for network inside container ${CT_ID}."
  msg_error "Check bridge '${BRIDGE}' and DHCP availability."
  exit 1
fi

# ── Pull and execute the install script ───────────────────────────────────────
INSTALL_URL="https://raw.githubusercontent.com/nutstownwarrior/proxmox-mcp-script/main/mcp-hub-install.sh"

msg_info "Pulling and running mcp-hub-install.sh inside container ${CT_ID}..."
pct exec "${CT_ID}" -- bash -c \
  "curl -fsSL '${INSTALL_URL}' -o /tmp/mcp-hub-install.sh && chmod +x /tmp/mcp-hub-install.sh && bash /tmp/mcp-hub-install.sh"

# ── Print final info ───────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  MCP Hub provisioned successfully!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

CT_IP=$(pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<container-ip>")

echo -e "  Container IP   : ${BOLD}${CT_IP}${NC}"
echo -e "  Health check   : ${CYN}curl http://${CT_IP}:8080/health${NC}"
echo -e "  Full summary   : ${CYN}pct exec ${CT_ID} -- cat /root/mcp-hub-info.txt${NC}"
echo ""
echo -e "  ${YLW}View the post-install summary now?${NC}"
pct exec "${CT_ID}" -- cat /root/mcp-hub-info.txt 2>/dev/null || true
echo ""
