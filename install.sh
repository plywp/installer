#!/usr/bin/env bash
# ============================================================
#  PlyWP Installer  v2
#  Installs PlyWP (panel + plyorde daemon) on your server
#  https://github.com/plywp
# ============================================================
set -e

RESET="\e[0m"
BOLD="\e[1m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
DIM="\e[2m"

print_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "  ██████╗ ██╗  ██╗   ██╗██╗    ██╗██████╗ "
  echo "  ██╔══██╗██║  ╚██╗ ██╔╝██║    ██║██╔══██╗"
  echo "  ██████╔╝██║   ╚████╔╝ ██║ █╗ ██║██████╔╝"
  echo "  ██╔═══╝ ██║    ╚██╔╝  ██║███╗██║██╔═══╝ "
  echo "  ██║     ███████╗██║   ╚███╔███╔╝██║     "
  echo "  ╚═╝     ╚══════╝╚═╝    ╚══╝╚══╝ ╚═╝     "
  echo -e "${RESET}"
  echo -e "  ${WHITE}Open-source WordPress Management Platform${RESET}"
  echo -e "  ${CYAN}https://github.com/plywp${RESET}"
  echo ""
}

log_info()    { echo -e "  ${GREEN}[INFO]${RESET}  $*"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "  ${RED}[ERROR]${RESET} $*"; }
log_step()    { echo -e "  ${CYAN}[....] ${WHITE}$*${RESET}"; }
log_done()    { echo -e "  ${GREEN}[ OK ] ${RESET}$*"; }
log_section() {
  echo -e "\n${BOLD}${CYAN}──────────────────────────────────────────${RESET}"
  echo -e "${BOLD}${WHITE}  $*${RESET}"
  echo -e "${BOLD}${CYAN}──────────────────────────────────────────${RESET}"
}
ask()         { echo -e -n "  ${CYAN}?${RESET}  $* "; }
ask_default() {
  echo -e -n "  ${CYAN}?${RESET}  $1 ${DIM}[${2}]${RESET}: "
  read -r REPLY
  [[ -z "$REPLY" ]] && REPLY="$2"
}

abort() {
  log_error "$*"
  exit 1
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    abort "This installer must be run as root.  Try: sudo bash $0"
  fi
}

# Install the bare minimum needed before any other function runs.
# curl / git / gpg / unzip may all be missing on a fresh image.
bootstrap_deps() {
  local missing=()
  command -v curl  &>/dev/null || missing+=(curl)
  command -v git   &>/dev/null || missing+=(git)
  command -v gpg   &>/dev/null || missing+=(gpg)
  command -v unzip &>/dev/null || missing+=(unzip)
  command -v jq    &>/dev/null || missing+=(jq)

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_step "Bootstrapping missing tools: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq ca-certificates "${missing[@]}"
    log_done "Bootstrap tools ready."
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID,,}"
    OS_VERSION_ID="${VERSION_ID}"
    OS_PRETTY="${PRETTY_NAME}"
  else
    abort "Cannot detect OS — /etc/os-release not found."
  fi

  case "$OS_ID" in
    ubuntu|debian) PKG_MANAGER="apt" ;;
    *) abort "Unsupported OS: ${OS_PRETTY}. Only Debian/Ubuntu are supported." ;;
  esac

  log_info "Detected OS : ${OS_PRETTY}"
}

check_arch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)  BUN_ARCH="x64";    GO_ARCH="amd64" ;;
    aarch64|arm64) BUN_ARCH="aarch64"; GO_ARCH="arm64" ;;
    *)
      log_warn "Untested architecture: ${ARCH}. Proceeding anyway."
      BUN_ARCH="x64"; GO_ARCH="amd64"
      ;;
  esac
  log_info "Architecture: ${ARCH}"
}

fetch_latest_release() {
  log_step "Fetching latest plyorde release tag..."
  PLYORDE_VERSION=$(
    curl -fsSL "https://api.github.com/repos/plywp/plyorde/releases" \
    | jq -r '.[0].tag_name'
  )

  if [[ -z "$PLYORDE_VERSION" ]]; then
    log_warn "Could not fetch release tag — will build plyorde from source."
    PLYORDE_VERSION="main"
    PLYORDE_BUILD_FROM_SOURCE=true
  else
    log_done "Latest plyorde: ${PLYORDE_VERSION}"
    PLYORDE_BUILD_FROM_SOURCE=false
  fi
}


detect_existing_installation() {
  local found_panel=false
  local found_daemon=false

  [[ -f /etc/systemd/system/plywp-panel.service ]] && found_panel=true
  [[ -f /etc/systemd/system/plyorde.service      ]] && found_daemon=true
  [[ -d /var/www/plywp-panel                     ]] && found_panel=true
  [[ -x /usr/local/bin/plyorde                   ]] && found_daemon=true

  if [[ "$found_panel" == true || "$found_daemon" == true ]]; then
    echo ""
    log_warn "Existing PlyWP installation detected:"
    [[ "$found_panel"  == true ]] && log_warn "  Panel  : /var/www/plywp-panel"
    [[ "$found_daemon" == true ]] && log_warn "  Daemon : /usr/local/bin/plyorde"
    echo ""
    echo -e "  ${BOLD}What would you like to do?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Reinstall / upgrade ${DIM}(stops services, wipes files, keeps databases)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Uninstall PlyWP"
    echo -e "  ${CYAN}[0]${RESET} Exit"
    echo ""
    ask "Enter choice [0-2]:"
    read -r EXIST_CHOICE
    case "$EXIST_CHOICE" in
      1)
        log_step "Removing existing installation..."
        for svc in plyorde plywp-panel; do
          systemctl stop    "$svc" 2>/dev/null || true
          systemctl disable "$svc" 2>/dev/null || true
          rm -f "/etc/systemd/system/${svc}.service"
        done
        systemctl daemon-reload
        rm -f  /usr/local/bin/plyorde /usr/local/bin/bun
        rm -rf /opt/plyorde /etc/plyorde /var/www/plywp-panel
        rm -f  /etc/nginx/sites-enabled/plywp.conf /etc/nginx/sites-available/plywp.conf
        rm -f  /etc/caddy/Caddyfile
        id plywp &>/dev/null && userdel -r plywp 2>/dev/null || true
        log_done "Existing installation removed — proceeding with fresh install."
        ;;
      2)
        run_uninstall
        exit 0
        ;;
      0) echo "Bye."; exit 0 ;;
      *) abort "Invalid choice." ;;
    esac
  fi
}

main_menu() {
  echo ""
  echo -e "  ${BOLD}What would you like to do?${RESET}"
  echo ""
  echo -e "  ${CYAN}[1]${RESET} Install PlyWP Panel + Plyorde daemon  ${YELLOW}(recommended — full stack)${RESET}"
  echo -e "  ${CYAN}[2]${RESET} Install Plyorde daemon only"
  echo -e "  ${CYAN}[3]${RESET} Install PlyWP Panel only"
  echo -e "  ${CYAN}[4]${RESET} Uninstall PlyWP"
  echo -e "  ${CYAN}[0]${RESET} Exit"
  echo ""
  ask "Enter choice [0-4]:"
  read -r INSTALL_CHOICE

  case "$INSTALL_CHOICE" in
    1) INSTALL_PANEL=true;  INSTALL_DAEMON=true  ;;
    2) INSTALL_PANEL=false; INSTALL_DAEMON=true  ;;
    3) INSTALL_PANEL=true;  INSTALL_DAEMON=false ;;
    4) run_uninstall; exit 0 ;;
    0) echo "Bye."; exit 0 ;;
    *) abort "Invalid choice: ${INSTALL_CHOICE}" ;;
  esac
}

webserver_menu() {
  echo ""
  echo -e "  ${BOLD}Which web server / reverse proxy?${RESET}"
  echo ""
  echo -e "  ${CYAN}[1]${RESET} Nginx  ${YELLOW}(recommended)${RESET}"
  echo -e "  ${CYAN}[2]${RESET} Caddy  ${DIM}(auto HTTPS — needs a real domain)${RESET}"
  echo ""
  ask "Enter choice [1-2]:"
  read -r WS_CHOICE
  case "$WS_CHOICE" in
    1) WEBSERVER="nginx" ;;
    2) WEBSERVER="caddy" ;;
    *) log_warn "Invalid choice, defaulting to nginx."; WEBSERVER="nginx" ;;
  esac
}

php_version_menu() {
  echo ""
  echo -e "  ${BOLD}Which PHP version? (used by WordPress sites managed by plyorde)${RESET}"
  echo ""
  echo -e "  ${CYAN}[1]${RESET} PHP 8.2  ${YELLOW}(recommended)${RESET}"
  echo -e "  ${CYAN}[2]${RESET} PHP 8.3"
  echo -e "  ${CYAN}[3]${RESET} PHP 8.1"
  echo ""
  ask "Enter choice [1-3]:"
  read -r PHP_CHOICE
  case "$PHP_CHOICE" in
    1) PHP_VERSION="8.2" ;;
    2) PHP_VERSION="8.3" ;;
    3) PHP_VERSION="8.1" ;;
    *) log_warn "Defaulting to PHP 8.2."; PHP_VERSION="8.2" ;;
  esac
}

collect_panel_config() {
  log_section "Panel Configuration"
  echo -e "  ${DIM}These values go into the panel's .env file.${RESET}"
  echo ""

  log_step "Detecting public IP via ifconfig.me..."
  PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
  if [[ -z "$PUBLIC_IP" ]]; then
    log_warn "Could not reach ifconfig.me — falling back to local IP."
    PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
  else
    log_done "Public IP: ${PUBLIC_IP}"
  fi

  ask_default "Panel public URL (ORIGIN — must match exactly what users visit)" \
    "http://${PUBLIC_IP}"
  PANEL_ORIGIN="${REPLY%/}"

  ask_default "Panel Node.js internal port" "3000"
  PANEL_PORT="$REPLY"

  echo ""
  echo -e "  ${BOLD}SMTP settings${RESET} ${DIM}(leave defaults to disable — edit .env later)${RESET}"

  ask_default "SMTP host"              "smtp.example.com"; SMTP_HOST="$REPLY"
  ask_default "SMTP port"              "587";              SMTP_PORT="$REPLY"
  ask_default "SMTP TLS (true/false)"  "false";            SMTP_SECURE="$REPLY"
  ask_default "SMTP enabled (true/false)" "false";         SMTP_ENABLED="$REPLY"
  ask_default "SMTP username"          "";                 SMTP_USER="$REPLY"

  echo -e -n "  ${CYAN}?${RESET}  SMTP password: "
  read -rs SMTP_PASS; echo ""

  ask_default "SMTP from address" "no-reply@example.com"; SMTP_FROM="$REPLY"

  BETTER_AUTH_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)
  log_done "BETTER_AUTH_SECRET generated (48 chars)."
}

confirm_install() {
  echo ""
  log_section "Installation Summary"
  echo ""
  [[ "$INSTALL_DAEMON" == true ]] && log_info "Component : Plyorde daemon"
  [[ "$INSTALL_PANEL"  == true ]] && log_info "Component : PlyWP Panel  (SvelteKit → Node.js + bun)"
  log_info "OS        : ${OS_PRETTY}"
  log_info "Web server: ${WEBSERVER}  (reverse proxy)"
  [[ "$INSTALL_DAEMON" == true ]] && log_info "PHP       : ${PHP_VERSION}"
  [[ "$INSTALL_PANEL"  == true ]] && log_info "Panel URL : ${PANEL_ORIGIN}  (internal port ${PANEL_PORT})"
  if [[ "$PLYORDE_BUILD_FROM_SOURCE" == false ]]; then
    log_info "Plyorde   : ${PLYORDE_VERSION} (pre-built binary)"
  else
    log_info "Plyorde   : built from source (Go required)"
  fi
  echo ""
  ask "Proceed with installation? [y/N]:"
  read -r CONFIRM
  [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || abort "Installation cancelled."
}

install_base_dependencies() {
  log_section "Installing Base Dependencies"
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    git unzip tar wget sudo systemd openssl
  log_done "Base dependencies ready."
}

install_system_tools() {
  log_section "Installing System Tools"
  apt-get install -y -qq \
    acl procps cron at \
    util-linux e2fsprogs findutils coreutils passwd
  log_done "System tools ready."
}

install_mariadb() {
  log_section "Installing MariaDB"
  if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
    log_info "MariaDB/MySQL already present — skipping install."
  else
    apt-get install -y -qq mariadb-server mariadb-client
  fi
  systemctl enable mariadb --quiet
  systemctl start  mariadb
  log_done "MariaDB running."
}

configure_databases() {
  log_section "Configuring Databases"

  PLYORDE_DB_NAME="plyorde"
  PLYORDE_DB_USER="plyorde"
  PLYORDE_DB_PASS=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 24)

  PANEL_DB_NAME="panel"
  PANEL_DB_USER="panel"
  PANEL_DB_PASS=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 24)

  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${PLYORDE_DB_NAME}\`;
CREATE USER IF NOT EXISTS '${PLYORDE_DB_USER}'@'localhost' IDENTIFIED BY '${PLYORDE_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PLYORDE_DB_NAME}\`.* TO '${PLYORDE_DB_USER}'@'localhost';

CREATE DATABASE IF NOT EXISTS \`${PANEL_DB_NAME}\`;
CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${PANEL_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PANEL_DB_NAME}\`.* TO '${PANEL_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  log_done "DB '${PLYORDE_DB_NAME}' (plyorde) and '${PANEL_DB_NAME}' (panel) created."
}

install_php() {
  log_section "Installing PHP ${PHP_VERSION}"

  if [[ "$OS_ID" == "ubuntu" ]]; then
    if ! grep -r "ondrej/php" /etc/apt/sources.list.d/ &>/dev/null; then
      apt-get install -y -qq software-properties-common
      add-apt-repository -y ppa:ondrej/php
      apt-get update -qq
    fi
  else
    if ! grep -r "sury" /etc/apt/sources.list.d/ &>/dev/null; then
      curl -fsSL https://packages.sury.org/php/apt.gpg \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg
      echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
      apt-get update -qq
    fi
  fi

  apt-get install -y -qq \
    "php${PHP_VERSION}-cli"     "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-mysql"   "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-zip"     "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-intl"

  systemctl enable "php${PHP_VERSION}-fpm" --quiet
  systemctl start  "php${PHP_VERSION}-fpm"
  log_done "PHP ${PHP_VERSION} + php-fpm running."
}

install_wpcli() {
  log_section "Installing WP-CLI"
  if command -v wp &>/dev/null; then
    log_info "WP-CLI already installed — skipping."
    return
  fi
  curl -fsSL \
    https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
  log_done "WP-CLI installed."
}

install_go() {
  log_section "Installing Go Toolchain"
  if command -v go &>/dev/null; then
    log_info "Go already installed ($(go version | awk '{print $3}')) — skipping."
    return
  fi

  GO_VERSION="1.24.4"
  GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  log_step "Downloading Go ${GO_VERSION}..."
  curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${GO_TAR}"
  rm "/tmp/${GO_TAR}"

  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  export PATH="$PATH:/usr/local/go/bin"
  log_done "Go ${GO_VERSION} installed."
}

install_bun() {
  log_section "Installing Bun (panel runtime)"

  BUN_BIN="/usr/local/bin/bun"

  if [[ -x "$BUN_BIN" ]]; then
    log_info "Bun already installed ($("$BUN_BIN" --version)) — skipping."
    return
  fi

  # The bun installer always puts the binary in ~/.bun/bin regardless of
  # BUN_INSTALL. Install there, then copy to /usr/local/bin so all users
  # and systemd services can reach it without access to /root.
  log_step "Downloading and installing Bun..."
  curl -fsSL https://bun.sh/install | bash

  if [[ ! -x "${HOME}/.bun/bin/bun" ]]; then
    abort "Bun installer did not produce ${HOME}/.bun/bin/bun — aborting."
  fi

  cp "${HOME}/.bun/bin/bun" /usr/local/bin/bun
  chmod 755 /usr/local/bin/bun
  log_done "Bun $(/usr/local/bin/bun --version) installed → /usr/local/bin/bun"

  export PATH="/usr/local/bin:${PATH}"
}

install_webserver() {
  log_section "Installing Web Server: ${WEBSERVER}"

  if [[ "$WEBSERVER" == "nginx" ]]; then
    apt-get install -y -qq nginx
    systemctl enable nginx --quiet
    systemctl start  nginx
  else
    apt-get install -y -qq apt-transport-https
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /etc/apt/trusted.gpg.d/caddy-stable.gpg
    echo "deb [trusted=yes] https://apt.fury.io/caddy/ /" \
      > /etc/apt/sources.list.d/caddy-fury.list
    apt-get update -qq
    apt-get install -y -qq caddy
    systemctl enable caddy --quiet
    systemctl start  caddy
  fi

  log_done "${WEBSERVER} installed and running."
}

install_plyorde() {
  log_section "Installing Plyorde Daemon"

  PLYORDE_SRC_DIR="/opt/plyorde"
  PLYORDE_CONFIG_DIR="/etc/plyorde"
  PLYORDE_BIN="/usr/local/bin/plyorde"

  mkdir -p "$PLYORDE_CONFIG_DIR"

  if [[ "$PLYORDE_BUILD_FROM_SOURCE" == true ]]; then
    log_step "Cloning plyorde source..."
    rm -rf "$PLYORDE_SRC_DIR"
    git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
    cd "$PLYORDE_SRC_DIR"
    log_step "Building plyorde binary (Go)..."
    /usr/local/go/bin/go build -o "$PLYORDE_BIN" .
    log_done "Plyorde built from source."
  else
    DOWNLOAD_URL="https://github.com/plywp/plyorde/releases/download/${PLYORDE_VERSION}/$(GO_ARCH)-linux-plyorde"
    log_step "Downloading plyorde ${PLYORDE_VERSION}..."
    if curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
      curl -fsSL "$DOWNLOAD_URL" -o "$PLYORDE_BIN"
      chmod +x "$PLYORDE_BIN"
      log_done "Plyorde binary downloaded."
    else
      log_warn "Pre-built binary not available for ${GO_ARCH} — building from source."
      PLYORDE_BUILD_FROM_SOURCE=true
      install_go
      rm -rf "$PLYORDE_SRC_DIR"
      git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
      cd "$PLYORDE_SRC_DIR"
      /usr/local/go/bin/go build -o "$PLYORDE_BIN" .
      log_done "Plyorde built from source (fallback)."
    fi
  fi

  chmod +x "$PLYORDE_BIN"

  cat > "${PLYORDE_CONFIG_DIR}/config.toml" <<TOML
# Plyorde configuration — generated by plywp-installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Restart plyorde after editing: systemctl restart plyorde

[database]
  host     = "127.0.0.1"
  port     = 3306
  name     = "${PLYORDE_DB_NAME}"
  user     = "${PLYORDE_DB_USER}"
  password = "${PLYORDE_DB_PASS}"

[daemon]
  listen = "127.0.0.1:8743"

[webserver]
  type = "${WEBSERVER}"

[php]
  version = "${PHP_VERSION}"
TOML

  log_done "Config written → ${PLYORDE_CONFIG_DIR}/config.toml"

  INIT_SQL="${PLYORDE_SRC_DIR}/init_db.sql"
  if [[ -f "$INIT_SQL" ]]; then
    log_step "Importing plyorde database schema..."
    mysql -u root "${PLYORDE_DB_NAME}" < "$INIT_SQL" \
      && log_done "Schema imported." \
      || log_warn "Schema import failed — run manually: mysql -u root ${PLYORDE_DB_NAME} < ${INIT_SQL}"
  fi

  cat > /etc/systemd/system/plyorde.service <<SERVICE
[Unit]
Description=Plyorde — PlyWP System Daemon
After=network.target mariadb.service
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${PLYORDE_BIN} --config ${PLYORDE_CONFIG_DIR}/config.toml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  # Enable so plyorde starts on reboot after the user has configured it,
  # but do NOT start it now — it needs a connector token first.
  systemctl enable plyorde --quiet

  echo ""
  log_warn "Plyorde has been installed but NOT started."
  echo ""
  echo -e "  ${BOLD}You must configure it before starting:${RESET}"
  echo ""
  echo -e "  ${CYAN}1.${RESET} Open the PlyWP panel in your browser and create a connector."
  echo -e "  ${CYAN}2.${RESET} Copy the connector token into:"
  echo -e "     ${BOLD}/etc/plyorde/config.toml${RESET}"
  echo -e "  ${CYAN}3.${RESET} Start the daemon:"
  echo -e "     ${BOLD}systemctl start plyorde${RESET}"
  echo -e "  ${CYAN}4.${RESET} Verify it is running:"
  echo -e "     ${BOLD}journalctl -u plyorde -f${RESET}"
  echo ""
}

install_panel() {
  log_section "Installing PlyWP Panel"

  PANEL_DIR="/var/www/plywp-panel"
  PANEL_USER="plywp"

  if ! id "$PANEL_USER" &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin \
      --home-dir "$PANEL_DIR" --create-home "$PANEL_USER"
    log_done "System user '${PANEL_USER}' created."
  fi

  log_step "Cloning PlyWP Panel source..."
  if [[ -d "${PANEL_DIR}/.git" ]]; then
    git -C "$PANEL_DIR" pull --quiet
    log_done "Panel source updated."
  else
    rm -rf "$PANEL_DIR"
    git clone --depth=1 https://github.com/plywp/panel.git "$PANEL_DIR"
    log_done "Panel source cloned → ${PANEL_DIR}"
  fi
  chown -R "${PANEL_USER}:${PANEL_USER}" "$PANEL_DIR"

  install_bun

  log_step "Writing .env..."
  cat > "${PANEL_DIR}/.env" <<ENV
# PlyWP Panel — generated by plywp-installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Edit and restart: systemctl restart plywp-panel

DATABASE_USER=${PANEL_DB_USER}
DATABASE_PASSWORD=${PANEL_DB_PASS}
DATABASE_HOST=localhost
DATABASE_PORT=3306
DATABASE_NAME=${PANEL_DB_NAME}

BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}

ORIGIN=${PANEL_ORIGIN}
BETTER_AUTH_URL=${PANEL_ORIGIN}

SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_SECURE=${SMTP_SECURE}
SMTP_ENABLED=${SMTP_ENABLED}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_FROM="${SMTP_FROM}"
ENV

  chmod 600 "${PANEL_DIR}/.env"
  chown "${PANEL_USER}:${PANEL_USER}" "${PANEL_DIR}/.env"
  log_done ".env written (mode 600)."

  log_step "Installing panel dependencies (bun install --frozen-lockfile)..."
  cd "$PANEL_DIR"
  bun install --frozen-lockfile
  log_done "Dependencies installed."

  # Replace adapter-auto with adapter-node so the build produces a standalone
  # Node.js server in build/index.js that the systemd service can run directly.
  # Correct syntax per https://svelte.dev/docs/cli/sveltekit-adapter
  log_step "Configuring adapter-node (bun x sv add sveltekit-adapter=\"adapter:node\")..."
  cd "$PANEL_DIR"
  yes | bun x --yes sv add "sveltekit-adapter=adapter:node" --install bun \
    && log_done "adapter-node configured." \
    || log_warn "sv add sveltekit-adapter failed — build may fail; check svelte.config.js"

  log_step "Running Drizzle database migrations (bun run db:migrate)..."
  cd "$PANEL_DIR"
  bun run db:migrate \
    && log_done "Drizzle migrations applied." \
    || log_warn "Migrations may have failed — re-run manually: cd ${PANEL_DIR} && bun run db:migrate"

  log_step "Building panel for production (bun run build)..."
  cd "$PANEL_DIR"
  bun run build
  chown -R "${PANEL_USER}:${PANEL_USER}" "$PANEL_DIR"
  log_done "Panel built → ${PANEL_DIR}/build/"

  cat > /etc/systemd/system/plywp-panel.service <<SERVICE
[Unit]
Description=PlyWP Panel (SvelteKit / Node.js via Bun)
After=network.target mariadb.service
Wants=network.target

[Service]
Type=simple
User=${PANEL_USER}
WorkingDirectory=${PANEL_DIR}
EnvironmentFile=${PANEL_DIR}/.env
Environment=PORT=${PANEL_PORT}
Environment=HOST=127.0.0.1
ExecStart=/usr/local/bin/bun ${PANEL_DIR}/build/index.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable plywp-panel --quiet
  systemctl start  plywp-panel \
    && log_done "plywp-panel service started." \
    || log_warn "Panel service failed to start — check: journalctl -u plywp-panel"

  configure_vhost
  create_admin_user
}


collect_admin_credentials() {
  log_section "Admin Account"
  echo -e "  ${DIM}Create the first admin user for the PlyWP panel.${RESET}"
  echo ""

  ask_default "Admin name"  "Admin";       ADMIN_NAME="$REPLY"
  ask_default "Admin email" "admin@example.com"; ADMIN_EMAIL="$REPLY"

  while true; do
    echo -e -n "  ${CYAN}?${RESET}  Admin password (min 8 chars): "
    read -rs ADMIN_PASS; echo ""
    if [[ ${#ADMIN_PASS} -lt 8 ]]; then
      log_warn "Password too short — must be at least 8 characters."
    else
      echo -e -n "  ${CYAN}?${RESET}  Confirm password: "
      read -rs ADMIN_PASS2; echo ""
      if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
        log_warn "Passwords do not match — try again."
      else
        break
      fi
    fi
  done
}

create_admin_user() {
  log_section "Creating Admin User"
  log_step "Running bun run add-user..."

  cd "$PANEL_DIR"

  ADMIN_NAME="$ADMIN_NAME" \
  ADMIN_EMAIL="$ADMIN_EMAIL" \
  ADMIN_PASSWORD="$ADMIN_PASS" \
  bun run add-user "$ADMIN_NAME" "$ADMIN_EMAIL" "$ADMIN_PASS" "admin" "$ADMIN_NAME org" \
    && log_done "Admin user '${ADMIN_EMAIL}' created." \
    || {
      log_warn "add-user script failed — run manually:"
      echo -e "  ${DIM}cd ${PANEL_DIR} && ADMIN_NAME='...' ADMIN_EMAIL='...' ADMIN_PASSWORD='...' bun run add-user${RESET}"
    }
}

configure_vhost() {
  log_section "Configuring ${WEBSERVER} Reverse Proxy"

  if [[ "$WEBSERVER" == "nginx" ]]; then
    cat > /etc/nginx/sites-available/plywp.conf <<NGINX
server {
    listen 80;
    server_name _;

    # Increase proxy buffer sizes to handle large response headers.
    # better-auth serialises session data into cookies on routes like
    # /dashboard, which easily exceeds Nginx's default 4k/8k buffers
    # and causes "upstream sent too big header" errors.
    # proxy_buffer_size  — max size of the response *header* buffer
    # proxy_buffers      — number + size of body buffers
    # proxy_busy_buffers_size — max in use while actively sending
    proxy_buffer_size       128k;
    proxy_buffers           4 256k;
    proxy_busy_buffers_size 256k;

    location / {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection 'upgrade';

        proxy_set_header Host               \$host;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_cache_bypass \$http_upgrade;

        proxy_read_timeout    300s;
        proxy_send_timeout    300s;
        proxy_connect_timeout 10s;
    }

    access_log /var/log/nginx/plywp_access.log;
    error_log  /var/log/nginx/plywp_error.log;
}
NGINX

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/plywp.conf \
           /etc/nginx/sites-enabled/plywp.conf

    nginx -t \
      && systemctl reload nginx \
      && log_done "Nginx reverse proxy configured." \
      || log_warn "Nginx config test failed — check: nginx -t"

  else
    CADDY_HOST="${PANEL_ORIGIN#http://}"
    CADDY_HOST="${CADDY_HOST#https://}"

    cat > /etc/caddy/Caddyfile <<CADDY
${CADDY_HOST} {
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}
CADDY

    systemctl reload caddy \
      && log_done "Caddy reverse proxy configured." \
      || log_warn "Caddy reload failed — check: /etc/caddy/Caddyfile"
  fi
}

run_uninstall() {
  log_section "Uninstalling PlyWP"
  ask "Stop & remove plyorde, panel service, files, and vhosts? [y/N]:"
  read -r UNCONFIRM
  [[ "${UNCONFIRM,,}" == "y" || "${UNCONFIRM,,}" == "yes" ]] \
    || { echo "Aborted."; return; }

  for svc in plyorde plywp-panel; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  done
  systemctl daemon-reload

  rm -f  /usr/local/bin/plyorde
  rm -rf /opt/plyorde /etc/plyorde /var/www/plywp-panel

  rm -f /etc/nginx/sites-enabled/plywp.conf
  rm -f /etc/nginx/sites-available/plywp.conf
  rm -f /etc/caddy/Caddyfile

  systemctl reload nginx 2>/dev/null || true
  systemctl reload caddy 2>/dev/null || true

  id plywp &>/dev/null && userdel plywp 2>/dev/null || true

  log_done "PlyWP removed."
  log_warn "Databases were NOT dropped. To remove them:"
  echo -e "  ${DIM}mysql -u root -e \"DROP DATABASE panel; DROP DATABASE plyorde;\"${RESET}"
  echo -e "  ${DIM}mysql -u root -e \"DROP USER 'panel'@'localhost'; DROP USER 'plyorde'@'localhost';\"${RESET}"
}

print_summary() {
  log_section "Installation Complete"
  echo ""

  if [[ "$INSTALL_PANEL" == true ]]; then
    echo -e "  ${GREEN}Panel URL  :${RESET} ${BOLD}${PANEL_ORIGIN}${RESET}"
    echo -e "  ${DIM}Panel DB   : ${PANEL_DB_NAME}  user: ${PANEL_DB_USER}  pass: ${PANEL_DB_PASS}${RESET}"
    echo -e "  ${DIM}Panel .env : /var/www/plywp-panel/.env${RESET}"
    echo -e "  ${DIM}Panel logs : journalctl -u plywp-panel -f${RESET}"
    echo ""
  fi

  if [[ "$INSTALL_DAEMON" == true ]]; then
    echo -e "  ${GREEN}Plyorde    :${RESET} ${BOLD}installed — awaiting configuration${RESET}"
    echo -e "  ${DIM}Plyorde DB : ${PLYORDE_DB_NAME}  user: ${PLYORDE_DB_USER}  pass: ${PLYORDE_DB_PASS}${RESET}"
    echo -e "  ${DIM}Plyorde cfg: /etc/plyorde/config.toml${RESET}"
    echo -e "  ${DIM}Daemon logs: journalctl -u plyorde -f${RESET}"
    echo ""
  fi

  echo -e "  ${BOLD}Next steps:${RESET}"
  echo -e "  ${CYAN}1.${RESET} Open the panel in your browser: ${BOLD}${PANEL_ORIGIN:-http://your-server}${RESET}"
  echo -e "  ${CYAN}2.${RESET} Create a connector in the panel UI"
  echo -e "  ${CYAN}3.${RESET} Paste the connector token into ${BOLD}/etc/plyorde/config.toml${RESET}"
  echo -e "  ${CYAN}4.${RESET} Start plyorde: ${BOLD}systemctl start plyorde${RESET}"
  echo ""
  echo -e "  ${YELLOW}Useful commands:${RESET}"
  echo -e "  ${DIM}cd /var/www/plywp-panel && bun run db:migrate   # re-run migrations${RESET}"
  echo -e "  ${DIM}cd /var/www/plywp-panel && bun run db:studio    # open Drizzle Studio${RESET}"
  echo -e "  ${DIM}systemctl restart plywp-panel                   # restart after .env changes${RESET}"
  echo ""
  log_warn "PlyWP / Plyorde is ALPHA software — expect bugs."
  echo ""
}

main() {
  print_banner
  check_root
  bootstrap_deps
  detect_os
  check_arch
  fetch_latest_release

  detect_existing_installation
  main_menu
  webserver_menu
  [[ "$INSTALL_DAEMON" == true ]] && php_version_menu
  [[ "$INSTALL_PANEL"  == true ]] && collect_panel_config
  [[ "$INSTALL_PANEL"  == true ]] && collect_admin_credentials
  confirm_install

  install_base_dependencies
  install_system_tools
  install_mariadb
  configure_databases

  if [[ "$INSTALL_DAEMON" == true ]]; then
    install_php
    install_wpcli
    install_webserver
    [[ "$PLYORDE_BUILD_FROM_SOURCE" == true ]] && install_go
    install_plyorde
  fi

  if [[ "$INSTALL_PANEL" == true ]]; then
    [[ "$INSTALL_DAEMON" == false ]] && install_webserver
    install_panel
  fi

  print_summary
}

main "$@"
