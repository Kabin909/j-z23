#!/usr/bin/env bash
# ============================================================
# ZJ Panel VPS Installer & Manager
# Menu: Panel / Wings / Update / Uninstall / Domain / Exit
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="ZJ Panel"
APP_DIR="${ZJ_PANEL_DIR:-/opt/zj-panel}"
SERVICE_NAME="zj-panel"
PANEL_PORT="${ZJ_PANEL_PORT:-6767}"
WINGS_BIN="/usr/local/bin/wings"
WINGS_DIR="/etc/pterodactyl"
WINGS_SERVICE="wings"
REPO_URL="${ZJ_REPO_URL:-https://github.com/JishnuTheGamer/Zj.git}"
BACKUP_DIR="/var/backups/zj-panel"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log(){ printf '%b\n' "${BLUE}[INFO]${NC} $*"; }
ok(){ printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn(){ printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
err(){ printf '%b\n' "${RED}[ERROR]${NC} $*" >&2; }
die(){ err "$*"; exit 1; }

trap 'err "Installation stopped at line $LINENO. Check the message above."' ERR

require_root(){
  [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash install.sh"
}

has(){ command -v "$1" >/dev/null 2>&1; }

pause(){ read -r -p $'\nPress Enter to return to the main menu...' _ || true; }

banner(){
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}"
  echo '============================================================'
  echo '                    ZJ PANEL INSTALLER'
  echo '============================================================'
  echo " Panel directory : ${APP_DIR}"
  echo " Panel port      : ${PANEL_PORT}"
  echo '============================================================'
  printf '%b\n' "${NC}"
}

os_check(){
  [[ -f /etc/os-release ]] || die "Cannot detect Linux distribution."
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) warn "${PRETTY_NAME:-This OS} is not officially tested by this installer. Ubuntu/Debian are recommended." ;;
  esac
  [[ "$(uname -s)" == "Linux" ]] || die "Linux is required."
}

apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a || true
  apt-get update
  apt-get install -y "$@"
}

install_base(){
  if has apt-get; then
    apt_install ca-certificates curl git build-essential jq unzip tar xz-utils nginx certbot python3-certbot-nginx openssl dnsutils
  elif has dnf; then
    dnf install -y ca-certificates curl git gcc-c++ make jq unzip tar xz openssl nginx bind-utils
  elif has yum; then
    yum install -y ca-certificates curl git gcc-c++ make jq unzip tar xz openssl nginx bind-utils
  else
    die "Supported package manager not found. Use Ubuntu/Debian."
  fi
}

node_ready(){
  if ! has node; then return 1; fi
  local major minor
  major="$(node -p 'process.versions.node.split(".")[0]')"
  minor="$(node -p 'process.versions.node.split(".")[1]')"
  if (( major >= 22 )); then return 0; fi
  if (( major == 20 && minor >= 19 )); then return 0; fi
  return 1
}

install_node(){
  if node_ready; then ok "Node.js $(node -v) is ready."; return; fi
  log "Installing Node.js 22.x..."
  if has apt-get; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  else
    die "Node.js automatic installation is currently implemented for Debian/Ubuntu."
  fi
  node_ready || die "Node.js 20.19+ or 22+ is required. Found: $(node -v 2>/dev/null || echo missing)"
  ok "Node.js $(node -v) installed."
}

install_docker(){
  if has docker; then
    docker info >/dev/null 2>&1 || {
      if has systemctl; then systemctl enable --now docker || true; fi
    }
    docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not available."
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') is ready."
    return
  fi
  log "Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
  has systemctl && systemctl enable --now docker || true
  docker info >/dev/null 2>&1 || die "Docker installation completed but daemon is unavailable."
  ok "Docker is ready."
}

ensure_env(){
  mkdir -p "${APP_DIR}"
  if [[ ! -f "${APP_DIR}/.env" ]]; then
    local secret
    secret="$(openssl rand -hex 48)"
    cat > "${APP_DIR}/.env" <<ENV
NODE_ENV=production
PORT=${PANEL_PORT}
JWT_SECRET=${secret}
DOCKER_SOCKET_PATH=/var/run/docker.sock
VITE_ENABLE_DEVELOPER_PANEL=false
ENV
    chmod 600 "${APP_DIR}/.env"
  else
    chmod 600 "${APP_DIR}/.env"
    if ! grep -q '^JWT_SECRET=' "${APP_DIR}/.env"; then
      echo "JWT_SECRET=$(openssl rand -hex 48)" >> "${APP_DIR}/.env"
    fi
  fi
}

prepare_source(){
  local here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${here}/package.json" && -f "${here}/server.ts" ]]; then
    if [[ "${here}" != "${APP_DIR}" ]]; then
      log "Copying local ZJ source to ${APP_DIR}..."
      mkdir -p "${APP_DIR}"
      rsync -a --delete --exclude '.git/' --exclude 'node_modules/' --exclude 'dist/' --exclude '.data/' --exclude 'backups/' "${here}/" "${APP_DIR}/"
    fi
  elif [[ -d "${APP_DIR}/.git" ]]; then
    log "Updating source from ${REPO_URL}..."
    git -C "${APP_DIR}" fetch --all --prune
    git -C "${APP_DIR}" reset --hard origin/HEAD || git -C "${APP_DIR}" pull --ff-only
  else
    log "Cloning ZJ source..."
    rm -rf "${APP_DIR}"
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
  fi
  [[ -f "${APP_DIR}/package.json" ]] || die "ZJ source was not found in ${APP_DIR}."
}

install_rsync_if_needed(){
  has rsync || { has apt-get && apt_install rsync; }
  has rsync || die "rsync is required for safe local source deployment."
}

systemd_panel(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=ZJ Panel
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=__NODE_BIN__ ${APP_DIR}/dist/server.cjs
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
  local node_bin
  node_bin="$(command -v node)"
  sed -i "s#__NODE_BIN__#${node_bin}#g" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

install_panel(){
  banner; echo -e "${BOLD}1) Install Panel${NC}\n"
  require_root; os_check; install_base; install_rsync_if_needed; install_node; install_docker
  prepare_source
  ensure_env
  cd "${APP_DIR}"
  log "Installing dependencies..."
  if [[ -f package-lock.json ]]; then npm ci --omit=optional; else npm install --omit=optional; fi
  log "Type-checking..."
  npm run lint
  log "Building production bundle..."
  npm run build
  mkdir -p "${APP_DIR}/.data" "${APP_DIR}/backups"
  systemd_panel
  ok "Panel service installed."
  echo
  echo "Local URL: http://$(hostname -I | awk '{print $1}'):${PANEL_PORT}"
  echo "Service  : systemctl status ${SERVICE_NAME}"
  echo "Logs     : journalctl -u ${SERVICE_NAME} -f"
  echo
  if [[ ! -f "${APP_DIR}/.data/users.json" || "$(cat "${APP_DIR}/.data/users.json" 2>/dev/null || echo '[]')" == "[]" ]]; then
    log "Creating the first admin account..."
    npm run createuser
  else
    ok "Existing user database detected; no admin account was overwritten."
  fi
}

install_wings(){
  banner; echo -e "${BOLD}2) Install Wings${NC}\n"
  require_root; os_check; install_base; install_docker
  mkdir -p "${WINGS_DIR}" /var/lib/pterodactyl/volumes /var/log/pterodactyl
  chmod 755 "${WINGS_DIR}"
  local arch asset
  case "$(uname -m)" in
    x86_64|amd64) asset="wings_linux_amd64" ;;
    aarch64|arm64) asset="wings_linux_arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  log "Downloading latest stable Wings binary (${asset})..."
  curl -fL --retry 3 --retry-delay 2 -o "${WINGS_BIN}.new" "https://github.com/pterodactyl/wings/releases/latest/download/${asset}"
  [[ -s "${WINGS_BIN}.new" ]] || die "Wings download was empty."
  chmod 755 "${WINGS_BIN}.new"
  mv -f "${WINGS_BIN}.new" "${WINGS_BIN}"
  cat > /etc/systemd/system/wings.service <<UNIT
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=${WINGS_DIR}
LimitNOFILE=4096
ExecStart=${WINGS_BIN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable wings
  if [[ ! -f "${WINGS_DIR}/config.yml" ]]; then
    cat > "${WINGS_DIR}/README-FIRST.txt" <<TXT
ZJ Panel Wings node setup

1. Install Wings (already done).
2. In ZJ Panel create/configure a node and generate its Wings configuration.
3. Save the generated config as:
   ${WINGS_DIR}/config.yml
4. Then run:
   systemctl restart wings
   systemctl status wings

Do not invent a node token/config; it must come from the panel's node configuration.
TXT
    warn "Wings binary/service installed, but config.yml is not generated yet. Configure the node in the panel first."
  else
    systemctl restart wings
    ok "Existing Wings config detected; Wings restarted."
  fi
  echo "Binary: ${WINGS_BIN}"
  echo "Config: ${WINGS_DIR}/config.yml"
  echo "Logs  : journalctl -u wings -f"
}

update_panel(){
  banner; echo -e "${BOLD}3) Update${NC}\n"; require_root
  [[ -d "${APP_DIR}" ]] || die "Panel is not installed at ${APP_DIR}."
  mkdir -p "${BACKUP_DIR}"
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_DIR}/panel-${stamp}.tar.gz"
  log "Backing up application data and environment..."
  tar -czf "${backup}" -C "${APP_DIR}" .env .data backups 2>/dev/null || true
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "${APP_DIR}" fetch --all --prune
    git -C "${APP_DIR}" reset --hard origin/HEAD || git -C "${APP_DIR}" pull --ff-only
  else
    warn "${APP_DIR} is not a Git checkout; update will rebuild the currently installed source."
  fi
  ensure_env
  cd "${APP_DIR}"
  [[ -f package-lock.json ]] && npm ci --omit=optional || npm install --omit=optional
  npm run lint
  npm run build
  systemctl restart "${SERVICE_NAME}"
  ok "Panel updated and restarted. Backup: ${backup}"
}

update_wings(){
  require_root
  if [[ ! -x "${WINGS_BIN}" ]]; then install_wings; return; fi
  systemctl stop wings 2>/dev/null || true
  local arch asset
  case "$(uname -m)" in
    x86_64|amd64) asset="wings_linux_amd64" ;;
    aarch64|arm64) asset="wings_linux_arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  curl -fL --retry 3 -o "${WINGS_BIN}.new" "https://github.com/pterodactyl/wings/releases/latest/download/${asset}"
  chmod 755 "${WINGS_BIN}.new"
  mv -f "${WINGS_BIN}.new" "${WINGS_BIN}"
  if [[ -f "${WINGS_DIR}/config.yml" ]]; then systemctl start wings; else warn "Wings config.yml is still missing; service remains stopped."; fi
  ok "Wings binary updated."
}

update_all(){
  banner; echo -e "${BOLD}3) Update${NC}\n"
  update_panel
  if [[ -x "${WINGS_BIN}" ]]; then update_wings; fi
}

uninstall_panel(){
  banner; echo -e "${BOLD}4) Uninstall${NC}\n"
  require_root
  read -r -p "Type UNINSTALL to continue: " confirm
  [[ "${confirm}" == "UNINSTALL" ]] || { warn "Cancelled."; return; }
  mkdir -p "${BACKUP_DIR}"
  local stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -d "${APP_DIR}" ]]; then
    tar -czf "${BACKUP_DIR}/before-uninstall-${stamp}.tar.gz" -C "${APP_DIR}" .env .data backups 2>/dev/null || true
  fi
  systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  read -r -p "Delete panel files in ${APP_DIR}? [y/N]: " del
  if [[ "${del}" =~ ^[Yy]$ ]]; then rm -rf "${APP_DIR}"; fi
  ok "Panel service removed. Backup kept in ${BACKUP_DIR}."
}

uninstall_wings(){
  require_root
  systemctl disable --now wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload
  rm -f "${WINGS_BIN}"
  read -r -p "Delete Wings configuration/data under ${WINGS_DIR} and /var/lib/pterodactyl? [y/N]: " del
  if [[ "${del}" =~ ^[Yy]$ ]]; then rm -rf "${WINGS_DIR}" /var/lib/pterodactyl /var/log/pterodactyl; fi
  ok "Wings service/binary removed."
}

uninstall_all(){
  uninstall_panel
  echo
  read -r -p "Also uninstall Wings? [y/N]: " w
  [[ "${w}" =~ ^[Yy]$ ]] && uninstall_wings || true
}

valid_domain(){
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

add_domain(){
  banner; echo -e "${BOLD}5) Add Domain${NC}\n"; require_root
  install_base
  read -r -p "Enter domain (example: panel.example.com): " DOMAIN
  DOMAIN="${DOMAIN,,}"
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
  valid_domain "${DOMAIN}" || die "Invalid domain name."
  [[ -d "${APP_DIR}" ]] || die "Install the panel first."

  local server_ip dns_ip
  server_ip="$(curl -4fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"
  dns_ip="$(dig +short A "${DOMAIN}" | tail -n1 || true)"
  if [[ -n "${dns_ip}" && "${dns_ip}" != "${server_ip}" ]]; then
    warn "DNS A record currently points to ${dns_ip}, while this server appears to be ${server_ip}."
    read -r -p "Continue anyway? [y/N]: " c
    [[ "${c}" =~ ^[Yy]$ ]] || return
  elif [[ -z "${dns_ip}" ]]; then
    warn "No A record was detected. Create an A record for ${DOMAIN} -> ${server_ip} first."
  else
    ok "DNS A record points to this server."
  fi

  cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 50g;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
NGINX
  ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  read -r -p "Install a free Let's Encrypt SSL certificate now? [Y/n]: " ssl
  if [[ ! "${ssl}" =~ ^[Nn]$ ]]; then
    if certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email -d "${DOMAIN}"; then
      ok "HTTPS enabled: https://${DOMAIN}"
    else
      warn "SSL issuance failed. Check DNS and ports 80/443, then run: certbot --nginx -d ${DOMAIN}"
    fi
  fi
  systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
  ok "Domain configuration completed for ${DOMAIN}."
}

status(){
  banner
  echo -e "${BOLD}Service status${NC}\n"
  systemctl --no-pager --full status "${SERVICE_NAME}" 2>/dev/null | sed -n '1,12p' || true
  echo
  systemctl --no-pager --full status wings 2>/dev/null | sed -n '1,12p' || true
}

menu(){
  while true; do
    banner
    echo -e "  ${BOLD}1)${NC} Install Panel"
    echo -e "  ${BOLD}2)${NC} Install Wings"
    echo -e "  ${BOLD}3)${NC} Update"
    echo -e "  ${BOLD}4)${NC} Uninstall"
    echo -e "  ${BOLD}5)${NC} Add Domain"
    echo -e "  ${BOLD}6)${NC} Exit"
    echo
    read -r -p " Select an option [1-6]: " choice
    case "$choice" in
      1) install_panel; pause ;;
      2) install_wings; pause ;;
      3) update_all; pause ;;
      4) uninstall_all; pause ;;
      5) add_domain; pause ;;
      6) echo "Goodbye."; exit 0 ;;
      *) err "Invalid option. Choose 1-6."; sleep 1 ;;
    esac
  done
}

require_root
menu
