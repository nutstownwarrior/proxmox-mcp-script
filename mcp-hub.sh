#!/usr/bin/env bash
# mcp-hub.sh — MCP Hub LXC Provisioner (Docker edition)
# Run this on the Proxmox HOST shell.
#
# Creates a Debian 12 LXC container with Docker + Compose, then bootstraps
# it with mcp-hub-install.sh pulled from GitHub.
#
# Self-contained — no external framework dependencies.

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

msg_info()  { echo -e "  ${BLU}[•]${NC} $*"; }
msg_ok()    { echo -e "  ${GRN}[✓]${NC} $*"; }
msg_error() { echo -e "  ${RED}[✗]${NC} $*" >&2; exit 1; }
msg_warn()  { echo -e "  ${YLW}[!]${NC} $*"; }

[[ $EUID -ne 0 ]] && msg_error "Run as root on the Proxmox host."
command -v pct &>/dev/null || msg_error "'pct' not found — must run on a Proxmox VE host."

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — Docker LXC Provisioner${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYN}Debian 12 · Unprivileged · Nesting + keyctl enabled${NC}"
echo -e "  ${CYN}2 CPU cores · 2 GB RAM · 10 GB disk · Docker + Compose${NC}"
echo ""

# ── Mode selection ─────────────────────────────────────────────────────────────
echo -e "  ${YLW}Mode:${NC}"
echo -e "    1) Create a new LXC container (recommended)"
echo -e "    2) Use an existing LXC that already has Docker installed"
echo ""
read -rp "  Choice [default: 1]: " MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

if [[ "${MODE_CHOICE}" == "2" ]]; then
  read -rp "  Existing container ID: " CT_ID
  [[ -z "${CT_ID}" ]] && msg_error "No container ID provided."
  pct status "${CT_ID}" &>/dev/null || msg_error "Container ${CT_ID} not found."

  msg_info "Using existing container ${CT_ID}"
  CT_IP=$(pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<unknown>")
  msg_ok "Container IP: ${CT_IP}"
else
  # ── Interactive prompts ──────────────────────────────────────────────────────
  read -rp "  Container ID    [default: 200]:       " CT_ID
  read -rp "  Hostname        [default: mcp-hub]:   " CT_HN
  read -rp "  Storage         [default: local-lvm]: " STOR
  read -rp "  Network bridge  [default: vmbr0]:     " BRIDGE

  CT_ID="${CT_ID:-200}"
  CT_HN="${CT_HN:-mcp-hub}"
  STOR="${STOR:-local-lvm}"
  BRIDGE="${BRIDGE:-vmbr0}"

  echo ""
  echo -e "  ${YLW}${BOLD}Summary:${NC}"
  echo -e "    Container ID : ${BOLD}${CT_ID}${NC}"
  echo -e "    Hostname     : ${BOLD}${CT_HN}${NC}"
  echo -e "    Storage      : ${BOLD}${STOR}${NC}"
  echo -e "    Bridge       : ${BOLD}${BRIDGE}${NC}"
  echo ""
  read -rp "  Proceed? [Y/n]: " CONFIRM
  [[ "${CONFIRM,,}" == "n" ]] && { echo "  Aborted."; exit 0; }
  echo ""

  pct status "${CT_ID}" &>/dev/null && msg_error "Container ${CT_ID} already exists."

  # ── Find or download Debian 12 template ─────────────────────────────────────
  TMPL_STORE="local"
  msg_info "Looking for Debian 12 template..."

  TEMPLATE=$(pveam list "${TMPL_STORE}" 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^debian-12-standard' \
    | sort -V | tail -1 || true)

  if [[ -z "${TEMPLATE}" ]]; then
    msg_info "Not found — refreshing catalog..."
    pveam update &>/dev/null
    AVAILABLE=$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '^debian-12-standard' \
      | sort -V | tail -1 || true)
    [[ -z "${AVAILABLE}" ]] && msg_error "No Debian 12 template found. Run 'pveam update'."
    msg_info "Downloading ${AVAILABLE}..."
    pveam download "${TMPL_STORE}" "${AVAILABLE}"
    TEMPLATE=$(pveam list "${TMPL_STORE}" 2>/dev/null \
      | awk '{print $1}' \
      | grep -E '^debian-12-standard' \
      | sort -V | tail -1)
  fi

  TEMPLATE_PATH="${TMPL_STORE}:vztmpl/${TEMPLATE}"
  msg_ok "Template: ${TEMPLATE_PATH}"

  # ── Create LXC ───────────────────────────────────────────────────────────────
  msg_info "Creating container ${CT_ID} (${CT_HN})..."
  pct create "${CT_ID}" "${TEMPLATE_PATH}" \
    --arch amd64 \
    --ostype debian \
    --hostname "${CT_HN}" \
    --cores 2 \
    --memory 2048 \
    --swap 512 \
    --rootfs "${STOR}:10" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=0" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 0
  msg_ok "Container ${CT_ID} created"

  msg_info "Starting container..."
  pct start "${CT_ID}"
  sleep 4
  msg_ok "Container started"

  # ── Wait for network ──────────────────────────────────────────────────────────
  msg_info "Waiting for network..."
  for i in $(seq 1 30); do
    if pct exec "${CT_ID}" -- ping -c1 -W2 1.1.1.1 &>/dev/null; then
      msg_ok "Network up (attempt ${i})"
      break
    fi
    [[ $i -eq 30 ]] && msg_error "Network timeout. Check bridge '${BRIDGE}' and DHCP."
    sleep 2
  done

  # ── Install Docker ───────────────────────────────────────────────────────────
  msg_info "Installing Docker + Compose inside container ${CT_ID}..."
  pct exec "${CT_ID}" -- bash -c '
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  '
  msg_ok "Docker $(pct exec "${CT_ID}" -- docker --version 2>/dev/null) installed"
fi

# ── Pull and run the install script ───────────────────────────────────────────
INSTALL_URL="https://raw.githubusercontent.com/nutstownwarrior/proxmox-mcp-script/main/mcp-hub-install.sh"

msg_info "Pulling mcp-hub-install.sh and running inside container ${CT_ID}..."
pct exec "${CT_ID}" -- bash -c \
  "curl -fsSL '${INSTALL_URL}' -o /tmp/mcp-hub-install.sh && bash /tmp/mcp-hub-install.sh"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  MCP Hub provisioned!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
CT_IP=$(pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<ip>")
echo -e "  Container IP : ${BOLD}${CT_IP}${NC}"
echo -e "  Health check : ${CYN}curl http://${CT_IP}:8080/health${NC}"
echo -e "  Full summary : ${CYN}pct exec ${CT_ID} -- cat /root/mcp-hub-info.txt${NC}"
echo ""
pct exec "${CT_ID}" -- cat /root/mcp-hub-info.txt 2>/dev/null || true
echo ""
