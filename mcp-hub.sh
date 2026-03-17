#!/usr/bin/env bash
# Copyright (c) 2021-2025 community-scripts ORG
# Author: Claude (Anthropic)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/zcaceres/gtasks-mcp

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="MCP-Hub"
var_tags="mcp;claude;ai;automation"
var_cpu="2"
var_ram="1024"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/mcp ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating gtasks-mcp"
  cd /opt/mcp/gtasks-mcp
  git pull -q
  npm install --silent
  npm run build --silent
  msg_ok "Updated gtasks-mcp"

  msg_info "Updating mcp-proxy"
  pip install --upgrade --quiet mcp-proxy --break-system-packages
  msg_ok "Updated mcp-proxy"

  msg_info "Updating cloudflared"
  RELEASE=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')
  wget -q "https://github.com/cloudflare/cloudflared/releases/download/${RELEASE}/cloudflared-linux-amd64.deb" -O /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb &>/dev/null
  rm -f /tmp/cloudflared.deb
  msg_ok "Updated cloudflared to ${RELEASE}"

  systemctl restart mcp-gtasks mcp-nginx 2>/dev/null || true
  msg_ok "Restarted services"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Next steps inside the container:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}1. Place gcp-oauth.keys.json at /opt/mcp/gtasks-mcp/gcp-oauth.keys.json${CL}"
echo -e "${TAB}${GATEWAY}${BGN}2. Run: cd /opt/mcp/gtasks-mcp && npm run start auth${CL}"
echo -e "${TAB}${GATEWAY}${BGN}3. Run: cloudflared tunnel login${CL}"
echo -e "${TAB}${GATEWAY}${BGN}4. Run: /opt/mcp/setup-tunnel.sh${CL}"
echo -e "${INFO}${YW} MCP proxy will be available at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080/gtasks/sse  (internal)${CL}"
