#!/usr/bin/env bash
# mcp-hub-install.sh — MCP Hub Docker Compose stack installer
# Run INSIDE the Docker LXC container (as root).
#
# Sets up a Docker Compose stack with:
#   - nginx reverse proxy (port 8080, bearer token auth, SSE support)
#   - gtasks-mcp  (Google Tasks MCP server via mcp-proxy)
#   - cloudflared (tunnel, started separately via --profile tunnel)
#
# Helper tools installed:
#   - /usr/local/bin/add-mcp-server   add more MCP servers in one command
#   - /opt/mcp-hub/setup-tunnel.sh    interactive Cloudflare Tunnel wizard
#
# No external framework dependencies — fully self-contained.

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

msg_info()  { echo -e "\n  ${BLU}[•]${NC} ${BOLD}$*${NC}"; }
msg_ok()    { echo -e "  ${GRN}[✓]${NC} $*"; }
msg_error() { echo -e "  ${RED}[✗]${NC} $*" >&2; exit 1; }
msg_warn()  { echo -e "  ${YLW}[!]${NC} $*"; }

[[ $EUID -ne 0 ]] && msg_error "Run as root."

echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — Docker Compose Stack Installer${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 1. Verify / install Docker ─────────────────────────────────────────────────
msg_info "Checking Docker"
if ! command -v docker &>/dev/null; then
  msg_warn "Docker not found — installing..."
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
fi
msg_ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# Verify Docker Compose (v2 plugin)
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi
msg_ok "Docker Compose $(docker compose version --short)"

# ── 2. Install helpers ────────────────────────────────────────────────────────
msg_info "Installing system utilities"
apt-get install -y -qq curl jq ufw openssl python3
msg_ok "Utilities installed"

# ── 3. Project structure ──────────────────────────────────────────────────────
HUB="/opt/mcp-hub"
msg_info "Creating project structure at ${HUB}"
mkdir -p \
  "${HUB}/nginx" \
  "${HUB}/services/gtasks/data" \
  "${HUB}/cloudflared" \
  "${HUB}/scripts"
msg_ok "Directory structure created"

# ── 4. Bearer token ───────────────────────────────────────────────────────────
msg_info "Generating bearer token"
BEARER_TOKEN=$(openssl rand -hex 32)
echo "${BEARER_TOKEN}" > "${HUB}/.bearer_token"
chmod 600 "${HUB}/.bearer_token"
msg_ok "Bearer token saved to ${HUB}/.bearer_token"

# ── 5. gtasks-mcp Dockerfile ──────────────────────────────────────────────────
msg_info "Creating gtasks-mcp Dockerfile"
cat > "${HUB}/services/gtasks/Dockerfile" <<'DOCKERFILE'
FROM node:20-slim

# Install Python (for mcp-proxy), git, curl
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install mcp-proxy — bridges stdio MCP servers to HTTP/SSE
RUN pip install mcp-proxy --break-system-packages --quiet

# Clone and build gtasks-mcp
RUN git clone --depth=1 https://github.com/zcaceres/gtasks-mcp /opt/gtasks-mcp && \
    cd /opt/gtasks-mcp && \
    npm ci --silent && \
    npm run build --silent

# Data directory for OAuth tokens
RUN mkdir -p /home/mcp && useradd -d /home/mcp -s /bin/sh mcp && \
    chown -R mcp:mcp /home/mcp /opt/gtasks-mcp

USER mcp
WORKDIR /opt/gtasks-mcp
EXPOSE 3100

CMD ["sh", "-c", "mcp-proxy --port 3100 -- node /opt/gtasks-mcp/dist/index.js"]
DOCKERFILE
msg_ok "gtasks Dockerfile created"

# ── 6. nginx config ───────────────────────────────────────────────────────────
msg_info "Creating nginx configuration"
cat > "${HUB}/nginx/nginx.conf" <<NGINXCONF
# MCP Hub — nginx reverse proxy
# Managed by mcp-hub-install.sh / add-mcp-server
# Bearer token is embedded directly (chmod 600 protects .bearer_token)

events {
    worker_connections 1024;
}

http {
    # Tune for long-lived SSE connections
    keepalive_timeout 3600;

    server {
        listen 8080;
        server_name _;

        # ── /health — no auth ────────────────────────────────────────────
        location /health {
            add_header Content-Type application/json always;
            return 200 '{"status":"ok","service":"mcp-hub"}';
        }

        # ── ADD NEW LOCATION BLOCKS ABOVE THIS COMMENT ──────────────────

        # ── /gtasks/ → gtasks container on :3100 ────────────────────────
        location /gtasks/ {
            set \$expected_token "${BEARER_TOKEN}";
            if (\$http_authorization != "Bearer \$expected_token") {
                add_header Content-Type application/json always;
                return 401 '{"error":"Unauthorized"}';
            }
            rewrite ^/gtasks/(.*)\$ /\$1 break;
            proxy_pass         http://gtasks:3100;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade           \$http_upgrade;
            proxy_set_header   Connection        "upgrade";
            proxy_set_header   Host              \$host;
            proxy_set_header   X-Real-IP         \$remote_addr;
            proxy_read_timeout  3600s;
            proxy_send_timeout  3600s;
            proxy_buffering     off;
            proxy_cache         off;
        }

        # ── catch-all ────────────────────────────────────────────────────
        location / {
            return 404;
        }
    }
}
NGINXCONF
msg_ok "nginx.conf created"

# ── 7. docker-compose.yml ─────────────────────────────────────────────────────
msg_info "Creating docker-compose.yml"
cat > "${HUB}/docker-compose.yml" <<COMPOSE
# MCP Hub — Docker Compose stack
# Add more servers with: add-mcp-server <name> <port> <git-url>

services:

  # ── Reverse proxy ────────────────────────────────────────────────────────
  nginx:
    image: nginx:alpine
    container_name: mcp-nginx
    ports:
      - "8080:8080"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3

  # ── ADD NEW SERVICES ABOVE THIS LINE ─────────────────────────────────────

  # ── gtasks MCP server ────────────────────────────────────────────────────
  gtasks:
    build:
      context: ./services/gtasks
    container_name: mcp-gtasks
    expose:
      - "3100"
    volumes:
      - ./services/gtasks/data:/home/mcp
    restart: unless-stopped
    environment:
      - HOME=/home/mcp
      - NODE_ENV=production

  # ── Cloudflare Tunnel (opt-in: docker compose --profile tunnel up -d) ───
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: mcp-cloudflared
    command: tunnel --config /etc/cloudflared/config.yml run
    volumes:
      - ./cloudflared:/etc/cloudflared:ro
      - cloudflared-creds:/root/.cloudflared
    restart: unless-stopped
    profiles:
      - tunnel

volumes:
  cloudflared-creds:
COMPOSE
msg_ok "docker-compose.yml created"

# ── 8. Build and start the stack ──────────────────────────────────────────────
msg_info "Building and starting MCP Hub stack (this may take a few minutes)..."
cd "${HUB}"
docker compose build --quiet
docker compose up -d
msg_ok "Stack is running"

# ── 9. add-mcp-server helper ──────────────────────────────────────────────────
msg_info "Installing /usr/local/bin/add-mcp-server"
cat > /usr/local/bin/add-mcp-server <<'HELPEREOF'
#!/usr/bin/env bash
# add-mcp-server — Add a new MCP server to the Docker Compose stack in one command
#
# Usage: add-mcp-server <name> <port> <git-url> [node-entry-point]
#
# Example:
#   add-mcp-server filesystem 3101 https://github.com/example/fs-mcp
#
# This creates:
#   /opt/mcp-hub/services/<name>/Dockerfile
#   /opt/mcp-hub/services/<name>/data/
# And updates docker-compose.yml + nginx.conf, then rebuilds.

set -euo pipefail

HUB="/opt/mcp-hub"
GRN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
die() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root."
[[ $# -lt 3 ]]    && die "Usage: add-mcp-server <name> <port> <git-url> [node-entry]"

NAME="$1"
PORT="$2"
GIT_URL="$3"
ENTRY="${4:-dist/index.js}"

BEARER_TOKEN=$(cat "${HUB}/.bearer_token")

[[ -d "${HUB}/services/${NAME}" ]] && die "Service '${NAME}' already exists."

# ── Create Dockerfile ─────────────────────────────────────────────────────────
mkdir -p "${HUB}/services/${NAME}/data"
cat > "${HUB}/services/${NAME}/Dockerfile" <<EOF
FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \\
      python3 python3-pip git curl ca-certificates && \\
    rm -rf /var/lib/apt/lists/*

RUN pip install mcp-proxy --break-system-packages --quiet

RUN git clone --depth=1 ${GIT_URL} /opt/${NAME} && \\
    cd /opt/${NAME} && npm ci --silent && npm run build --silent

RUN mkdir -p /home/mcp && useradd -d /home/mcp -s /bin/sh mcp && \\
    chown -R mcp:mcp /home/mcp /opt/${NAME}

USER mcp
WORKDIR /opt/${NAME}
EXPOSE ${PORT}

CMD ["sh", "-c", "mcp-proxy --port ${PORT} -- node /opt/${NAME}/${ENTRY}"]
EOF

# ── Inject nginx location block ───────────────────────────────────────────────
NGINX_BLOCK="
        # ── /${NAME}/ → ${NAME} container on :${PORT} ────────────────────────
        location /${NAME}/ {
            set \\\$expected_token \"${BEARER_TOKEN}\";
            if (\\\$http_authorization != \"Bearer \\\$expected_token\") {
                add_header Content-Type application/json always;
                return 401 '{\"error\":\"Unauthorized\"}';
            }
            rewrite ^/${NAME}/(.*)$ /\\\$1 break;
            proxy_pass         http://${NAME}:${PORT};
            proxy_http_version 1.1;
            proxy_set_header   Upgrade           \\\$http_upgrade;
            proxy_set_header   Connection        \"upgrade\";
            proxy_read_timeout  3600s;
            proxy_send_timeout  3600s;
            proxy_buffering     off;
            proxy_cache         off;
        }
"
sed -i "/ADD NEW LOCATION BLOCKS ABOVE THIS COMMENT/a\\${NGINX_BLOCK}" \
  "${HUB}/nginx/nginx.conf"

# ── Inject docker-compose service ────────────────────────────────────────────
SERVICE_BLOCK="
  ${NAME}:
    build:
      context: ./services/${NAME}
    container_name: mcp-${NAME}
    expose:
      - \"${PORT}\"
    volumes:
      - ./services/${NAME}/data:/home/mcp
    restart: unless-stopped
    environment:
      - HOME=/home/mcp
      - NODE_ENV=production
"
sed -i "/ADD NEW SERVICES ABOVE THIS LINE/a\\${SERVICE_BLOCK}" \
  "${HUB}/docker-compose.yml"

# ── Add nginx dependency ──────────────────────────────────────────────────────
# (nginx depends_on block would need updating too; skip for simplicity —
#  nginx will simply retry until the upstream is ready)

# ── Rebuild and restart ───────────────────────────────────────────────────────
cd "${HUB}"
docker compose build --quiet "${NAME}"
docker compose up -d

echo ""
echo -e "${GRN}${BOLD}✅  MCP server '${NAME}' added!${NC}"
echo ""
echo -e "  Internal  : http://localhost:8080/${NAME}/sse"
echo -e "  Token     : ${BEARER_TOKEN}"
echo -e "  Logs      : docker compose -f ${HUB}/docker-compose.yml logs -f ${NAME}"
echo ""
HELPEREOF
chmod +x /usr/local/bin/add-mcp-server
msg_ok "/usr/local/bin/add-mcp-server installed"

# ── 10. setup-tunnel.sh wizard ────────────────────────────────────────────────
msg_info "Installing ${HUB}/setup-tunnel.sh"
cat > "${HUB}/setup-tunnel.sh" <<'TUNNELEOF'
#!/usr/bin/env bash
# setup-tunnel.sh — Interactive Cloudflare Tunnel wizard (Docker edition)
#
# Run AFTER authenticating:
#   docker run -it --rm \
#     -v /opt/mcp-hub/cloudflared:/root/.cloudflared \
#     cloudflare/cloudflared:latest tunnel login
#
# This script then creates the tunnel, routes DNS, writes config.yml,
# and starts the cloudflared container via docker compose.

set -euo pipefail

HUB="/opt/mcp-hub"
BLU='\033[0;34m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLU}${BOLD}  MCP Hub — Cloudflare Tunnel Setup${NC}"
echo -e "${BLU}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check credentials exist
CREDS_DIR="${HUB}/cloudflared"
if [[ -z "$(ls -A "${CREDS_DIR}" 2>/dev/null)" ]]; then
  echo -e "  ${YLW}[!]${NC} No cloudflared credentials found."
  echo -e "  ${YLW}[!]${NC} Run this first to authenticate:"
  echo ""
  echo -e "    docker run -it --rm \\"
  echo -e "      -v ${CREDS_DIR}:/root/.cloudflared \\"
  echo -e "      cloudflare/cloudflared:latest tunnel login"
  echo ""
  exit 1
fi

read -rp "  Tunnel name     (e.g. proxmox-mcp):      " TUNNEL_NAME
read -rp "  Public hostname (e.g. mcp.example.com):  " HOSTNAME

[[ -z "${TUNNEL_NAME}" ]] && { echo "Tunnel name required."; exit 1; }
[[ -z "${HOSTNAME}" ]]    && { echo "Hostname required."; exit 1; }

# Create tunnel using Docker
echo -e "\n  ${BLU}[•]${NC} Creating tunnel '${TUNNEL_NAME}'..."
docker run --rm \
  -v "${CREDS_DIR}:/root/.cloudflared" \
  cloudflare/cloudflared:latest tunnel create "${TUNNEL_NAME}"

TUNNEL_ID=$(docker run --rm \
  -v "${CREDS_DIR}:/root/.cloudflared" \
  cloudflare/cloudflared:latest tunnel list --output json \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
name = '${TUNNEL_NAME}'
match = next((t['id'] for t in data if t['name'] == name), None)
print(match or '')
")

[[ -z "${TUNNEL_ID}" ]] && { echo "Failed to get tunnel ID."; exit 1; }

# Route DNS
echo -e "  ${BLU}[•]${NC} Routing ${HOSTNAME} → tunnel ${TUNNEL_ID}..."
docker run --rm \
  -v "${CREDS_DIR}:/root/.cloudflared" \
  cloudflare/cloudflared:latest tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"

# Write config.yml
cat > "${CREDS_DIR}/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
logfile: /var/log/cloudflared.log
loglevel: info

ingress:
  - hostname: ${HOSTNAME}
    service: http://nginx:8080
  - service: http_status:404
EOF

# Start cloudflared container
echo -e "  ${BLU}[•]${NC} Starting cloudflared container..."
cd "${HUB}"
docker compose --profile tunnel up -d cloudflared

BEARER_TOKEN=$(cat "${HUB}/.bearer_token")

echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  Tunnel live!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Endpoint  : ${BOLD}https://${HOSTNAME}/gtasks/sse${NC}"
echo -e "  Token     : ${BOLD}${BEARER_TOKEN}${NC}"
echo ""
echo -e "  Add to Claude.ai → Settings → Connectors → Add MCP Server"
echo ""
TUNNELEOF
chmod +x "${HUB}/setup-tunnel.sh"
msg_ok "setup-tunnel.sh installed"

# ── 11. UFW ────────────────────────────────────────────────────────────────────
msg_info "Configuring UFW firewall"
ufw --force reset    &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
ufw allow ssh         comment "SSH"           &>/dev/null
ufw allow 8080/tcp    comment "MCP nginx"     &>/dev/null
ufw --force enable    &>/dev/null
msg_ok "UFW: SSH + 8080 allowed, everything else denied"

# ── 12. Post-install summary ──────────────────────────────────────────────────
msg_info "Writing summary"
CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<this-ip>")
BEARER_TOKEN=$(cat "${HUB}/.bearer_token")

cat > /root/mcp-hub-info.txt <<EOF
╔══════════════════════════════════════════════════════════════╗
║           MCP Hub (Docker) — Post-Install Summary            ║
╚══════════════════════════════════════════════════════════════╝

Bearer Token  (keep secret):
  ${BEARER_TOKEN}

Internal endpoint (gtasks):
  http://${CT_IP}:8080/gtasks/sse

Health check (no auth):
  curl http://${CT_IP}:8080/health

Docker stack status:
  docker compose -f ${HUB}/docker-compose.yml ps

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

── Step 1: Google OAuth ─────────────────────────────────────────

  a) Google Cloud Console → Enable Tasks API → Create OAuth 2.0
     credentials (Desktop app) → Download JSON

  b) Copy into the container:
       scp gcp-oauth.keys.json root@${CT_IP}:/opt/mcp-hub/services/gtasks/data/

  c) Run auth flow inside the running container:
       docker exec -it mcp-gtasks sh -c \
         "node /opt/gtasks-mcp/dist/index.js auth"

── Step 2: Cloudflare Tunnel ────────────────────────────────────

  a) Authenticate (opens a browser link):
       docker run -it --rm \\
         -v /opt/mcp-hub/cloudflared:/root/.cloudflared \\
         cloudflare/cloudflared:latest tunnel login

  b) Run the setup wizard:
       /opt/mcp-hub/setup-tunnel.sh

── Step 3: Add connector in Claude.ai ──────────────────────────

  Go to Claude.ai → Settings → Connectors → Add MCP Server
    URL   : https://<your-hostname>/gtasks/sse
    Token : ${BEARER_TOKEN}

── Adding more MCP servers ──────────────────────────────────────

  add-mcp-server <name> <port> <git-url>

  Example:
    add-mcp-server filesystem 3101 https://github.com/example/fs-mcp

── Stack management ─────────────────────────────────────────────

  cd /opt/mcp-hub

  docker compose ps
  docker compose logs -f gtasks
  docker compose logs -f nginx
  docker compose restart gtasks

  # Rebuild after code changes:
  docker compose build gtasks && docker compose up -d gtasks

══════════════════════════════════════════════════════════════════
EOF
chmod 600 /root/mcp-hub-info.txt
msg_ok "Summary written to /root/mcp-hub-info.txt"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GRN}${BOLD}  MCP Hub Docker stack is up!${NC}"
echo -e "${GRN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYN}docker compose -f ${HUB}/docker-compose.yml ps${NC}"
echo ""
cd "${HUB}" && docker compose ps
echo ""
echo -e "  Bearer token : ${BOLD}${BEARER_TOKEN}${NC}"
echo -e "  Health check : ${CYN}curl http://${CT_IP}:8080/health${NC}"
echo -e "  Full guide   : ${CYN}cat /root/mcp-hub-info.txt${NC}"
echo ""
