#!/usr/bin/env bash
# Copyright (c) 2021-2025 community-scripts ORG
# Author: Claude (Anthropic)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/zcaceres/gtasks-mcp

source /dev/stdin <<< "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"

# ── Bootstrap ────────────────────────────────────────────────────────────────
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ── Dependencies ─────────────────────────────────────────────────────────────
msg_info "Installing dependencies"
$STD apt-get install -y \
  curl \
  git \
  wget \
  nginx \
  python3 \
  python3-pip \
  python3-venv \
  jq \
  ufw \
  lsb-release \
  gnupg2
msg_ok "Installed dependencies"

# ── Node.js 20.x ─────────────────────────────────────────────────────────────
msg_info "Installing Node.js 20.x"
$STD curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
$STD apt-get install -y nodejs
msg_ok "Installed Node.js $(node --version)"

# ── mcp-proxy (stdio → HTTP/SSE bridge) ──────────────────────────────────────
msg_info "Installing mcp-proxy"
$STD pip install mcp-proxy --break-system-packages
msg_ok "Installed mcp-proxy"

# ── cloudflared ───────────────────────────────────────────────────────────────
msg_info "Installing cloudflared"
RELEASE=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')
wget -q "https://github.com/cloudflare/cloudflared/releases/download/${RELEASE}/cloudflared-linux-amd64.deb" -O /tmp/cloudflared.deb
$STD dpkg -i /tmp/cloudflared.deb
rm -f /tmp/cloudflared.deb
echo "${RELEASE}" >/opt/cloudflared_version.txt
msg_ok "Installed cloudflared ${RELEASE}"

# ── Dedicated mcp system user ─────────────────────────────────────────────────
msg_info "Creating mcp system user"
useradd --system --shell /bin/bash --create-home --home-dir /opt/mcp mcp 2>/dev/null || true
msg_ok "Created mcp user"

# ── gtasks-mcp ────────────────────────────────────────────────────────────────
msg_info "Cloning and building gtasks-mcp"
mkdir -p /opt/mcp
cd /opt/mcp
$STD git clone https://github.com/zcaceres/gtasks-mcp.git
cd gtasks-mcp
$STD npm install
$STD npm run build
chown -R mcp:mcp /opt/mcp
msg_ok "Built gtasks-mcp"

# ── Generate a random bearer token ───────────────────────────────────────────
msg_info "Generating API bearer token"
BEARER_TOKEN=$(openssl rand -hex 32)
echo "${BEARER_TOKEN}" >/opt/mcp/.bearer_token
chmod 600 /opt/mcp/.bearer_token
chown mcp:mcp /opt/mcp/.bearer_token
msg_ok "Bearer token saved to /opt/mcp/.bearer_token"

# ── systemd: mcp-gtasks ───────────────────────────────────────────────────────
msg_info "Creating mcp-gtasks systemd service"
cat >/etc/systemd/system/mcp-gtasks.service <<EOF
[Unit]
Description=gtasks MCP Server (via mcp-proxy)
After=network.target

[Service]
Type=simple
User=mcp
WorkingDirectory=/opt/mcp/gtasks-mcp
ExecStart=$(which mcp-proxy) --port 3100 -- $(which node) /opt/mcp/gtasks-mcp/dist/index.js
Restart=always
RestartSec=5
Environment=HOME=/opt/mcp

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created mcp-gtasks service"

# ── nginx reverse proxy ───────────────────────────────────────────────────────
msg_info "Configuring nginx"
rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/sites-available/mcp <<'NGINXEOF'
server {
    listen 8080;
    server_name _;

    # ── /gtasks/ → mcp-proxy on :3100 ──────────────────────────────────────
    location /gtasks/ {
        # Strip the /gtasks prefix before forwarding
        rewrite ^/gtasks/(.*)$ /$1 break;

        proxy_pass         http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # Bearer token auth — populated by the install script
        set $expected_token "__BEARER_TOKEN__";
        if ($http_authorization != "Bearer $expected_token") {
            return 401 '{"error":"Unauthorized"}';
        }
    }

    # ── health endpoint (no auth) ───────────────────────────────────────────
    location /health {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    # ── catch-all ───────────────────────────────────────────────────────────
    location / {
        return 404;
    }
}
NGINXEOF

# Inject the real bearer token into the nginx config
sed -i "s|__BEARER_TOKEN__|${BEARER_TOKEN}|g" /etc/nginx/sites-available/mcp
ln -sf /etc/nginx/sites-available/mcp /etc/nginx/sites-enabled/mcp

# Validate config
nginx -t &>/dev/null
msg_ok "Configured nginx"

# ── systemd: enable & start services ─────────────────────────────────────────
msg_info "Enabling services"
systemctl daemon-reload
systemctl enable --now mcp-gtasks &>/dev/null
systemctl enable --now nginx &>/dev/null
msg_ok "Services enabled"

# ── helper: add-mcp-server ────────────────────────────────────────────────────
msg_info "Installing add-mcp-server helper script"
cat >/usr/local/bin/add-mcp-server <<'HELPEREOF'
#!/usr/bin/env bash
# Usage: add-mcp-server <name> <port> <command...>
# Example: add-mcp-server mytool 3101 node /opt/mcp/mytool/dist/index.js
set -euo pipefail

NAME="${1:?Usage: add-mcp-server <name> <port> <command...>}"
PORT="${2:?Missing port}"
shift 2
CMD="$*"
BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)

# systemd service
cat >"/etc/systemd/system/mcp-${NAME}.service" <<EOF
[Unit]
Description=${NAME} MCP Server (via mcp-proxy)
After=network.target

[Service]
Type=simple
User=mcp
ExecStart=$(which mcp-proxy) --port ${PORT} -- ${CMD}
Restart=always
RestartSec=5
Environment=HOME=/opt/mcp

[Install]
WantedBy=multi-user.target
EOF

# nginx location block
LOCATION_BLOCK="
    location /${NAME}/ {
        rewrite ^/${NAME}/(.*)$ /\$1 break;
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection \"upgrade\";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        set \$expected_token \"${BEARER_TOKEN}\";
        if (\$http_authorization != \"Bearer \$expected_token\") {
            return 401 '{\"error\":\"Unauthorized\"}';
        }
    }"

# Inject before the health block
sed -i "/location \/health/i\\${LOCATION_BLOCK}" /etc/nginx/sites-available/mcp
nginx -t && systemctl reload nginx

systemctl daemon-reload
systemctl enable --now "mcp-${NAME}"

echo ""
echo "✅  MCP server '${NAME}' added!"
echo "    Internal : http://localhost:8080/${NAME}/sse"
echo "    Token    : ${BEARER_TOKEN}"
HELPEREOF
chmod +x /usr/local/bin/add-mcp-server
msg_ok "Installed add-mcp-server helper"

# ── Cloudflare tunnel setup helper ───────────────────────────────────────────
msg_info "Installing tunnel setup helper"
cat >/opt/mcp/setup-tunnel.sh <<'TUNNELEOF'
#!/usr/bin/env bash
# Interactive helper — run after: cloudflared tunnel login
set -euo pipefail

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MCP Hub — Cloudflare Tunnel Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Enter a tunnel name (e.g. proxmox-mcp): " TUNNEL_NAME
read -rp "Enter your public hostname (e.g. mcp.yourdomain.com): " HOSTNAME

# Create tunnel
cloudflared tunnel create "${TUNNEL_NAME}"
TUNNEL_ID=$(cloudflared tunnel list --output json | jq -r --arg n "${TUNNEL_NAME}" '.[] | select(.name==$n) | .id')
cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"

# Write config
mkdir -p /etc/cloudflared
cat >"/etc/cloudflared/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
logfile: /var/log/cloudflared.log

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:8080
  - service: http_status:404
EOF

# Install as system service
cloudflared service install

echo ""
echo "✅  Tunnel configured!"
echo ""
echo "Your MCP endpoints are now public at:"
BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)
echo "  https://${HOSTNAME}/gtasks/sse"
echo ""
echo "Bearer token (add this in Claude.ai connector settings):"
echo "  ${BEARER_TOKEN}"
echo ""
echo "To add more MCP servers later:"
echo "  add-mcp-server <name> <port> <command>"
TUNNELEOF
chmod +x /opt/mcp/setup-tunnel.sh
msg_ok "Installed tunnel setup helper"

# ── UFW firewall ──────────────────────────────────────────────────────────────
msg_info "Configuring firewall"
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
ufw allow ssh &>/dev/null
ufw allow 8080/tcp comment "MCP nginx (internal only)" &>/dev/null
ufw --force enable &>/dev/null
msg_ok "Configured firewall (SSH + 8080 allowed)"

# ── Final status ──────────────────────────────────────────────────────────────
msg_info "Writing post-install summary"
BEARER_TOKEN=$(cat /opt/mcp/.bearer_token)
cat >/root/mcp-hub-info.txt <<EOF
╔══════════════════════════════════════════════════════╗
║           MCP Hub — Post-Install Summary             ║
╚══════════════════════════════════════════════════════╝

Bearer Token (keep this secret!):
  ${BEARER_TOKEN}

Internal MCP endpoint:
  http://$(hostname -I | awk '{print $1}'):8080/gtasks/sse

── Next Steps ──────────────────────────────────────────

1. Upload your Google OAuth key:
     scp gcp-oauth.keys.json root@<this-ip>:/opt/mcp/gtasks-mcp/

2. Complete Google auth (run inside this container):
     cd /opt/mcp/gtasks-mcp && npm run start auth

3. Log in to Cloudflare:
     cloudflared tunnel login

4. Set up the public tunnel:
     /opt/mcp/setup-tunnel.sh

5. Add the connector in Claude.ai:
     URL  : https://<your-hostname>/gtasks/sse
     Token: (see above)

── Adding More MCP Servers Later ───────────────────────

  add-mcp-server <name> <port> node /opt/mcp/<repo>/dist/index.js

── Service Management ──────────────────────────────────

  systemctl status mcp-gtasks
  systemctl status nginx
  journalctl -u mcp-gtasks -f

EOF
chmod 600 /root/mcp-hub-info.txt
msg_ok "Summary written to /root/mcp-hub-info.txt"
