#!/usr/bin/env bash
# mcp-hub-install.sh — MCP Hub Container Provisioner
# Run INSIDE a freshly created Debian 12 LXC container (as root).
#
# What this script does:
#   1. Install system dependencies (Node.js 20, nginx, python3, pip, git,
#      curl, jq, ufw, openssl, cloudflared)
#   2. Create a low-privilege 'mcp' system user  (/opt/mcp)
#   3. Clone + build gtasks-mcp
#   4. Install mcp-proxy  (stdio → HTTP/SSE bridge)
#   5. Generate a random bearer token
#   6. Create mcp-gtasks systemd service
#   7. Configure nginx (port 8080, /gtasks/, bearer auth, SSE, /health)
#   8. Install /usr/local/bin/add-mcp-server helper
#   9. Install /opt/mcp/setup-tunnel.sh (Cloudflare Tunnel wizard)
#  10. Configure UFW (deny all in except SSH + 8080)
#  11. Enable + start services
#  12. Write /root/mcp-hub-info.txt summary
#
# No external framework dependencies — fully self-contained.

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

msg_info()  { echo -e "\n  ${BLU}[•]${NC} ${BOLD}$*${NC}"; }
msg_ok()    { echo -e "  ${GRN}[✓]${NC} $*"; }
msg_error() { echo -e "  ${RED}[✗]${NC} $*" >&2; exit 1; }
msg_warn()  { echo -e "  ${YLW}[!]${NC} $*"; }

# ── Require root ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && msg_error "This script must be run as root."

# ── Header ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — Container Install Script${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 1. System dependencies ─────────────────────────────────────────────────────
msg_info "Updating package lists"
apt-get update -qq
msg_ok "Package lists updated"

msg_info "Installing base dependencies"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget git jq ufw openssl \
  python3 python3-pip \
  nginx \
  lsb-release gnupg2 ca-certificates
msg_ok "Base dependencies installed"

# ── Node.js 20.x ───────────────────────────────────────────────────────────────
msg_info "Installing Node.js 20.x"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
apt-get install -y -qq nodejs
msg_ok "Node.js $(node --version) installed"

# ── mcp-proxy (stdio → HTTP/SSE bridge) ───────────────────────────────────────
msg_info "Installing mcp-proxy"
pip install --quiet mcp-proxy --break-system-packages
msg_ok "mcp-proxy installed ($(mcp-proxy --version 2>/dev/null || echo 'ok'))"

# ── cloudflared (latest release from GitHub) ──────────────────────────────────
msg_info "Installing cloudflared (latest from GitHub)"
RELEASE=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
  | grep '"tag_name"' \
  | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "${RELEASE}" ]]; then
  msg_warn "Could not determine latest cloudflared release — using fallback 2024.12.2"
  RELEASE="2024.12.2"
fi

ARCH="amd64"
wget -q "https://github.com/cloudflare/cloudflared/releases/download/${RELEASE}/cloudflared-linux-${ARCH}.deb" \
  -O /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb &>/dev/null
rm -f /tmp/cloudflared.deb
echo "${RELEASE}" > /opt/cloudflared_version.txt
msg_ok "cloudflared ${RELEASE} installed"

# ── 2. mcp system user ────────────────────────────────────────────────────────
msg_info "Creating 'mcp' system user"
if ! id mcp &>/dev/null; then
  useradd \
    --system \
    --shell /bin/bash \
    --create-home \
    --home-dir /opt/mcp \
    mcp
fi
mkdir -p /opt/mcp
msg_ok "User 'mcp' created (home: /opt/mcp)"

# ── 3. gtasks-mcp ─────────────────────────────────────────────────────────────
msg_info "Cloning gtasks-mcp"
if [[ -d /opt/mcp/gtasks-mcp ]]; then
  msg_warn "/opt/mcp/gtasks-mcp already exists — pulling latest"
  git -C /opt/mcp/gtasks-mcp pull -q
else
  git clone -q https://github.com/zcaceres/gtasks-mcp.git /opt/mcp/gtasks-mcp
fi
msg_ok "gtasks-mcp cloned"

msg_info "Building gtasks-mcp (npm install + build)"
cd /opt/mcp/gtasks-mcp
npm install --silent
npm run build --silent
chown -R mcp:mcp /opt/mcp
msg_ok "gtasks-mcp built"

# ── 5. Bearer token ───────────────────────────────────────────────────────────
msg_info "Generating bearer token"
BEARER_TOKEN=$(openssl rand -hex 32)
echo "${BEARER_TOKEN}" > /opt/mcp/.bearer_token
chmod 600 /opt/mcp/.bearer_token
chown mcp:mcp /opt/mcp/.bearer_token
msg_ok "Bearer token saved to /opt/mcp/.bearer_token"

# ── Resolve binary paths (for use in service files) ───────────────────────────
MCP_PROXY_BIN=$(command -v mcp-proxy)
NODE_BIN=$(command -v node)

# ── 6. systemd: mcp-gtasks ────────────────────────────────────────────────────
msg_info "Creating mcp-gtasks systemd service"
cat > /etc/systemd/system/mcp-gtasks.service <<EOF
[Unit]
Description=gtasks MCP Server (mcp-proxy → stdio bridge)
After=network.target

[Service]
Type=simple
User=mcp
WorkingDirectory=/opt/mcp/gtasks-mcp
ExecStart=${MCP_PROXY_BIN} --port 3100 -- ${NODE_BIN} /opt/mcp/gtasks-mcp/dist/index.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=HOME=/opt/mcp
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
msg_ok "mcp-gtasks service created"

# ── 7. nginx configuration ────────────────────────────────────────────────────
msg_info "Configuring nginx (port 8080)"
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/mcp <<NGINXEOF
# MCP Hub — nginx reverse proxy
# Managed by mcp-hub-install.sh / add-mcp-server

server {
    listen 8080;
    server_name _;

    # ── /health — no auth ────────────────────────────────────────────────────
    location /health {
        add_header Content-Type application/json always;
        return 200 '{"status":"ok","service":"mcp-hub"}';
    }

    # ── /gtasks/ → mcp-proxy on :3100 ────────────────────────────────────────
    location /gtasks/ {
        # Enforce bearer token
        set \$expected_token "__BEARER_TOKEN__";
        if (\$http_authorization != "Bearer \$expected_token") {
            add_header Content-Type application/json always;
            return 401 '{"error":"Unauthorized"}';
        }

        # Strip the /gtasks prefix
        rewrite ^/gtasks/(.*)$ /\$1 break;

        proxy_pass         http://127.0.0.1:3100;
        proxy_http_version 1.1;

        # SSE / WebSocket support
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # Long timeouts for SSE streams
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
        proxy_cache         off;
    }

    # ── catch-all ─────────────────────────────────────────────────────────────
    location / {
        return 404;
    }
}
NGINXEOF

# Inject real bearer token
sed -i "s|__BEARER_TOKEN__|${BEARER_TOKEN}|g" /etc/nginx/sites-available/mcp
ln -sf /etc/nginx/sites-available/mcp /etc/nginx/sites-enabled/mcp

nginx -t 2>/dev/null
msg_ok "nginx configured (port 8080)"

# ── 8. add-mcp-server helper ──────────────────────────────────────────────────
msg_info "Installing /usr/local/bin/add-mcp-server helper"
cat > /usr/local/bin/add-mcp-server <<'HELPEREOF'
#!/usr/bin/env bash
# add-mcp-server — Add a new MCP server to the hub in one command.
#
# Usage: add-mcp-server <name> <port> <command...>
#
# Example:
#   add-mcp-server filesystem 3101 node /opt/mcp/filesystem-mcp/dist/index.js
#
# This will:
#   - Create a systemd service called mcp-<name>
#   - Add a location block /<name>/ to nginx with the same bearer token
#   - Start the service immediately

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'
die() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root."
[[ $# -lt 3 ]]    && die "Usage: add-mcp-server <name> <port> <command...>"

NAME="$1"
PORT="$2"
shift 2
CMD="$*"

BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)
MCP_PROXY_BIN=$(command -v mcp-proxy)

# Guard against duplicate
if [[ -f "/etc/systemd/system/mcp-${NAME}.service" ]]; then
  die "Service mcp-${NAME} already exists. Choose a different name."
fi

# ── systemd service ────────────────────────────────────────────────────────────
cat > "/etc/systemd/system/mcp-${NAME}.service" <<EOF
[Unit]
Description=${NAME} MCP Server (mcp-proxy → stdio bridge)
After=network.target

[Service]
Type=simple
User=mcp
ExecStart=${MCP_PROXY_BIN} --port ${PORT} -- ${CMD}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=HOME=/opt/mcp

[Install]
WantedBy=multi-user.target
EOF

# ── nginx location block ───────────────────────────────────────────────────────
# We insert the new location block just before the /health block
NGINX_CFG="/etc/nginx/sites-available/mcp"

NEW_BLOCK="
    # ── /${NAME}/ → mcp-proxy on :${PORT} ──────────────────────────────────────────
    location /${NAME}/ {
        set \\\$expected_token \"${BEARER_TOKEN}\";
        if (\\\$http_authorization != \"Bearer \\\$expected_token\") {
            add_header Content-Type application/json always;
            return 401 '{\"error\":\"Unauthorized\"}';
        }

        rewrite ^/${NAME}/(.*)\$ /\\\$1 break;
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \\\$http_upgrade;
        proxy_set_header   Connection        \"upgrade\";
        proxy_set_header   Host              \\\$host;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
        proxy_cache         off;
    }
"

# Insert before the /health block
sed -i "/location \/health/i\\${NEW_BLOCK}" "${NGINX_CFG}"
nginx -t && systemctl reload nginx

# ── Enable and start the new service ──────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now "mcp-${NAME}"

echo ""
echo -e "${GRN}${BOLD}✅  MCP server '${NAME}' added and started!${NC}"
echo ""
echo -e "  Internal  : http://localhost:8080/${NAME}/sse"
echo -e "  Token     : ${BEARER_TOKEN}"
echo -e "  Logs      : journalctl -u mcp-${NAME} -f"
echo ""
HELPEREOF
chmod +x /usr/local/bin/add-mcp-server
msg_ok "/usr/local/bin/add-mcp-server installed"

# ── 9. Cloudflare Tunnel setup wizard ─────────────────────────────────────────
msg_info "Installing /opt/mcp/setup-tunnel.sh wizard"
cat > /opt/mcp/setup-tunnel.sh <<'TUNNELEOF'
#!/usr/bin/env bash
# setup-tunnel.sh — Interactive Cloudflare Tunnel setup wizard
#
# Prerequisites (run these first):
#   cloudflared tunnel login
#
# This script will:
#   1. Create a named Cloudflare Tunnel
#   2. Route DNS to a public hostname you choose
#   3. Write /etc/cloudflared/config.yml
#   4. Install cloudflared as a system service

set -euo pipefail

BLU='\033[0;34m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — Cloudflare Tunnel Setup Wizard${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check cloudflared is authenticated
if [[ ! -d "$HOME/.cloudflared" ]] && [[ ! -d "/root/.cloudflared" ]]; then
  echo -e "  ${YLW}[!]${NC} It looks like you haven't logged in yet."
  echo -e "  ${YLW}[!]${NC} Run: ${BOLD}cloudflared tunnel login${NC}"
  echo -e "  ${YLW}[!]${NC} Then re-run this script."
  exit 1
fi

read -rp "  Tunnel name     (e.g. proxmox-mcp):      " TUNNEL_NAME
read -rp "  Public hostname (e.g. mcp.example.com):  " HOSTNAME

[[ -z "${TUNNEL_NAME}" ]] && { echo "Tunnel name cannot be empty."; exit 1; }
[[ -z "${HOSTNAME}" ]]    && { echo "Hostname cannot be empty."; exit 1; }

echo ""
echo -e "  ${BLU}[•]${NC} Creating tunnel '${TUNNEL_NAME}'..."
cloudflared tunnel create "${TUNNEL_NAME}"

TUNNEL_ID=$(cloudflared tunnel list --output json \
  | python3 -c "import sys,json; data=json.load(sys.stdin); \
    print(next(t['id'] for t in data if t['name']=='${TUNNEL_NAME}'))" \
  2>/dev/null \
  || cloudflared tunnel list --output json \
  | jq -r --arg n "${TUNNEL_NAME}" '.[] | select(.name==$n) | .id')

if [[ -z "${TUNNEL_ID}" ]]; then
  echo "  Failed to retrieve tunnel ID. Check 'cloudflared tunnel list'."
  exit 1
fi

echo -e "  ${BLU}[•]${NC} Routing DNS: ${HOSTNAME} → ${TUNNEL_NAME} (${TUNNEL_ID})"
cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"

# ── Write config ───────────────────────────────────────────────────────────────
mkdir -p /etc/cloudflared

CREDS_PATH="/root/.cloudflared/${TUNNEL_ID}.json"
[[ ! -f "${CREDS_PATH}" ]] && CREDS_PATH="$HOME/.cloudflared/${TUNNEL_ID}.json"

cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS_PATH}
logfile: /var/log/cloudflared.log
loglevel: info

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:8080
  - service: http_status:404
EOF

echo -e "  ${BLU}[•]${NC} Installing cloudflared as a system service..."
cloudflared service install

systemctl enable --now cloudflared 2>/dev/null || true

BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)

echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  Tunnel configured successfully!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Public endpoint : ${BOLD}https://${HOSTNAME}/gtasks/sse${NC}"
echo -e "  Bearer token    : ${BOLD}${BEARER_TOKEN}${NC}"
echo ""
echo -e "  Add to Claude.ai:"
echo -e "    URL   : https://${HOSTNAME}/gtasks/sse"
echo -e "    Token : ${BEARER_TOKEN}"
echo ""
echo -e "  To add more MCP servers:"
echo -e "    add-mcp-server <name> <port> <command>"
echo ""
TUNNELEOF
chmod +x /opt/mcp/setup-tunnel.sh
chown mcp:mcp /opt/mcp/setup-tunnel.sh
msg_ok "/opt/mcp/setup-tunnel.sh installed"

# ── 10. UFW firewall ──────────────────────────────────────────────────────────
msg_info "Configuring UFW firewall"
ufw --force reset    &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
ufw allow ssh         comment "SSH access"     &>/dev/null
ufw allow 8080/tcp    comment "MCP nginx proxy" &>/dev/null
ufw --force enable    &>/dev/null
msg_ok "UFW configured (SSH + 8080 allowed, all else denied)"

# ── 11. Enable and start services ─────────────────────────────────────────────
msg_info "Enabling and starting services"
systemctl daemon-reload
systemctl enable --now mcp-gtasks &>/dev/null
systemctl enable --now nginx      &>/dev/null
msg_ok "Services mcp-gtasks and nginx enabled and started"

# ── 12. Post-install summary ──────────────────────────────────────────────────
msg_info "Writing post-install summary"

CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-ip>")
BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)

cat > /root/mcp-hub-info.txt <<EOF
╔══════════════════════════════════════════════════════════════╗
║                MCP Hub — Post-Install Summary                ║
╚══════════════════════════════════════════════════════════════╝

Bearer Token (keep this secret — required for all MCP connections):
  ${BEARER_TOKEN}

Internal MCP Endpoint (gtasks):
  http://${CT_IP}:8080/gtasks/sse

Health Check (no auth required):
  curl http://${CT_IP}:8080/health

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── Step 1: Google OAuth Setup ──────────────────────────────────

  a) Go to https://console.cloud.google.com/
  b) Create/select a project, enable the Google Tasks API
  c) Create OAuth 2.0 credentials (Desktop application)
  d) Download the credentials JSON file

  e) Copy the file into the container:
       scp gcp-oauth.keys.json root@${CT_IP}:/opt/mcp/gtasks-mcp/gcp-oauth.keys.json

  f) Run the auth flow (inside this container):
       cd /opt/mcp/gtasks-mcp && sudo -u mcp node dist/index.js auth

── Step 2: Cloudflare Tunnel Login ─────────────────────────────

  a) Inside this container, run:
       cloudflared tunnel login
  b) Open the URL shown in your browser and authorise the zone/domain

── Step 3: Create and configure the tunnel ─────────────────────

  Run the interactive wizard:
    /opt/mcp/setup-tunnel.sh

  It will ask for:
    - Tunnel name  (e.g. proxmox-mcp)
    - Public hostname (e.g. mcp.yourdomain.com)

  It then creates the tunnel, routes DNS, writes
  /etc/cloudflared/config.yml, and installs the system service.

── Step 4: Add the connector in Claude.ai ──────────────────────

  1. Go to Claude.ai → Settings → Connectors → Add MCP Server
  2. Enter:
       URL   : https://<your-hostname>/gtasks/sse
       Token : ${BEARER_TOKEN}
  3. Click Connect and authorise

── Adding More MCP Servers Later ───────────────────────────────

  add-mcp-server <name> <port> <command>

  Example:
    add-mcp-server filesystem 3101 node /opt/mcp/fs-mcp/dist/index.js

  This creates the systemd service and injects the nginx location
  block automatically.

── Service Management ───────────────────────────────────────────

  systemctl status mcp-gtasks
  systemctl status nginx
  systemctl status cloudflared

  journalctl -u mcp-gtasks -f
  journalctl -u cloudflared -f

  nginx -t && systemctl reload nginx

══════════════════════════════════════════════════════════════════
EOF

chmod 600 /root/mcp-hub-info.txt
msg_ok "Summary written to /root/mcp-hub-info.txt"

# ── Final status banner ───────────────────────────────────────────────────────
echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  MCP Hub installation complete!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Container IP  : ${BOLD}${CT_IP}${NC}"
echo -e "  Health check  : ${CYN}curl http://${CT_IP}:8080/health${NC}"
echo -e "  Bearer token  : ${BOLD}${BEARER_TOKEN}${NC}"
echo ""
echo -e "  Full next steps: ${CYN}cat /root/mcp-hub-info.txt${NC}"
echo ""
