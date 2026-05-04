#!/usr/bin/env bash
# ============================================================
#  PlyWP Installer  v3
#  Installs PlyWP (panel + plyorde daemon) on your server
#  https://github.com/plywp
#
#  New in v3:
#    - Rollback system  (automatic cleanup on failure)
#    - TUI progress bar (tracks steps visually)
#    - Resume broken installs (checkpoint state file)
# ============================================================
set -euo pipefail

RESET="\e[0m"
BOLD="\e[1m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
DIM="\e[2m"
MAGENTA="\e[35m"
BG_RED="\e[41m"
BG_GREEN="\e[42m"

# ── Debug / dry-run state ────────────────────────────────────
DRY_RUN=false
DEBUG=false
LOG_FILE=""
INSTALLER_VERSION="3.0.0"
_SECTION_START=0
_INSTALL_START=$(date +%s)

# ── State / resume / rollback ────────────────────────────────
STATE_FILE="/var/lib/plywp-installer/state"
ROLLBACK_LOG="/var/lib/plywp-installer/rollback.log"
ROLLBACK_ENABLED=true
RESUME_MODE=false

# ── Progress bar state ───────────────────────────────────────
_PROGRESS_TOTAL=0
_PROGRESS_CURRENT=0
_PROGRESS_LABEL=""

# All install steps (ordered) — used for progress tracking and resume
INSTALL_STEPS=(
  "install_base_dependencies"
  "install_system_tools"
  "install_mariadb"
  "configure_databases"
  "install_php"
  "install_wpcli"
  "install_webserver"
  "install_go"
  "install_plyorde"
  "install_panel"
)

# Steps that are always run regardless of install mode
ALWAYS_STEPS=(
  "install_base_dependencies"
  "install_system_tools"
  "install_mariadb"
  "configure_databases"
)

# ── Argument parsing ─────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n)
        DRY_RUN=true
        shift
        ;;
      --debug|-d)
        DEBUG=true
        shift
        ;;
      --log-file|-l)
        [[ -n "${2:-}" ]] || { echo "ERROR: --log-file requires a path"; exit 1; }
        LOG_FILE="$2"
        shift 2
        ;;
      --log-file=*)
        LOG_FILE="${1#*=}"
        shift
        ;;
      --resume)
        RESUME_MODE=true
        shift
        ;;
      --no-rollback)
        ROLLBACK_ENABLED=false
        shift
        ;;
      --version|-v)
        echo "PlyWP Installer v${INSTALLER_VERSION}"
        exit 0
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        echo "Unknown option: $1  (try --help)"
        exit 1
        ;;
    esac
  done
}

print_help() {
  echo ""
  echo -e "${BOLD}PlyWP Installer v${INSTALLER_VERSION}${RESET}"
  echo ""
  echo "USAGE"
  echo "  sudo bash $0 [OPTIONS]"
  echo ""
  echo "OPTIONS"
  echo "  --dry-run, -n          Simulate the installation — no changes are made"
  echo "  --debug,   -d          Enable bash xtrace (set -x) and verbose logging"
  echo "  --log-file, -l <path>  Tee all output to <path> in addition to stdout"
  echo "  --resume               Resume a previously interrupted installation"
  echo "  --no-rollback          Disable automatic rollback on failure"
  echo "  --version, -v          Print installer version and exit"
  echo "  --help,    -h          Show this help and exit"
  echo ""
  echo "EXAMPLES"
  echo "  sudo bash $0 --dry-run"
  echo "  sudo bash $0 --debug --log-file /tmp/plywp-install.log"
  echo "  sudo bash $0 --resume"
  echo "  sudo bash $0 --dry-run --debug --log-file /tmp/plywp-dryrun.log"
  echo ""
}

# ── Logging setup ────────────────────────────────────────────
setup_logging() {
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Logging to: ${LOG_FILE}"
  fi
}

setup_debug() {
  if [[ "$DEBUG" == true ]]; then
    set -x
    log_debug "Debug mode enabled (bash xtrace on)"
  fi
}

# ── Print helpers ────────────────────────────────────────────
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

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}┌─────────────────────────────────────────┐${RESET}"
    echo -e "  ${YELLOW}${BOLD}│  DRY RUN MODE — no changes will be made  │${RESET}"
    echo -e "  ${YELLOW}${BOLD}└─────────────────────────────────────────┘${RESET}"
  fi

  if [[ "$RESUME_MODE" == true ]]; then
    echo ""
    echo -e "  ${CYAN}${BOLD}┌─────────────────────────────────────────┐${RESET}"
    echo -e "  ${CYAN}${BOLD}│  RESUME MODE — continuing prior install   │${RESET}"
    echo -e "  ${CYAN}${BOLD}└─────────────────────────────────────────┘${RESET}"
  fi

  if [[ "$DEBUG" == true ]]; then
    echo -e "  ${MAGENTA}${BOLD}[DEBUG MODE ACTIVE]${RESET}  version: ${INSTALLER_VERSION}"
  fi

  echo ""
}

log_info()    { echo -e "  ${GREEN}[INFO]${RESET}  $*"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "  ${RED}[ERROR]${RESET} $*"; }
log_step()    { echo -e "  ${CYAN}[....] ${WHITE}$*${RESET}"; }
log_done()    { echo -e "  ${GREEN}[ OK ] ${RESET}$*"; }
log_dry()     { echo -e "  ${YELLOW}[DRY ] ${DIM}$*${RESET}"; }
log_debug()   { [[ "$DEBUG" == true ]] && echo -e "  ${MAGENTA}[DBG ] ${DIM}$*${RESET}" || true; }
log_time()    { echo -e "  ${DIM}[TIME] $*${RESET}"; }
log_rollback(){ echo -e "  ${RED}[RLBK]${RESET} $*"; }
log_resume()  { echo -e "  ${CYAN}[SKIP]${RESET} ${DIM}$* (already completed — skipping)${RESET}"; }

log_section() {
  if [[ "$_SECTION_START" -ne 0 ]]; then
    local elapsed=$(( $(date +%s) - _SECTION_START ))
    log_time "Previous section took ${elapsed}s"
  fi
  _SECTION_START=$(date +%s)

  echo -e "\n${BOLD}${CYAN}──────────────────────────────────────────${RESET}"
  echo -e "${BOLD}${WHITE}  $*${RESET}"
  echo -e "${BOLD}${CYAN}──────────────────────────────────────────${RESET}"

  log_debug "Section start: $*"
}

ask()         { echo -e -n "  ${CYAN}?${RESET}  $* "; }
ask_default() {
  echo -e -n "  ${CYAN}?${RESET}  $1 ${DIM}[${2}]${RESET}: "
  read -r REPLY || REPLY=""
  [[ -z "$REPLY" ]] && REPLY="$2"
}

abort() {
  log_error "$*"
  print_elapsed_total
  exit 1
}

print_elapsed_total() {
  local total=$(( $(date +%s) - _INSTALL_START ))
  local mins=$(( total / 60 ))
  local secs=$(( total % 60 ))
  echo ""
  log_time "Total elapsed: ${mins}m ${secs}s"
}

# ════════════════════════════════════════════════════════════
#  PROGRESS BAR
# ════════════════════════════════════════════════════════════
#
#  Usage:
#    progress_init <total_steps>
#    progress_step "Step label"   — call before each major step
#    progress_done                — call at the very end
#
# The bar renders as:
#   [████████░░░░░░░░░░░░]  4/10  Installing MariaDB
#
progress_init() {
  _PROGRESS_TOTAL="${1:-10}"
  _PROGRESS_CURRENT=0
  _PROGRESS_LABEL=""
  _progress_render
}

progress_step() {
  _PROGRESS_LABEL="${1:-}"
  (( _PROGRESS_CURRENT++ )) || true
  _progress_render
}

progress_done() {
  _PROGRESS_CURRENT="$_PROGRESS_TOTAL"
  _PROGRESS_LABEL="Complete"
  _progress_render
  echo ""  # newline after final bar
}

_progress_render() {
  local width=40
  local filled=0
  local empty=0

  if [[ "$_PROGRESS_TOTAL" -gt 0 ]]; then
    filled=$(( (_PROGRESS_CURRENT * width) / _PROGRESS_TOTAL ))
  fi
  empty=$(( width - filled ))

  local bar=""
  local i
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done

  local pct=0
  [[ "$_PROGRESS_TOTAL" -gt 0 ]] && pct=$(( (_PROGRESS_CURRENT * 100) / _PROGRESS_TOTAL ))

  # Truncate label so it fits in 80 cols
  local label="${_PROGRESS_LABEL}"
  if [[ ${#label} -gt 30 ]]; then
    label="${label:0:27}..."
  fi

  # \r to overwrite the same line; \e[K clears to end of line
  printf "\r  ${CYAN}[${GREEN}%s${DIM}%s${CYAN}]${RESET}  %3d%%  %d/%d  ${WHITE}%-33s${RESET}\e[K" \
    "$bar" "" "$pct" "$_PROGRESS_CURRENT" "$_PROGRESS_TOTAL" "$label"

  # After final step, add a newline so the next log_* starts clean
  if [[ "$_PROGRESS_CURRENT" -ge "$_PROGRESS_TOTAL" ]]; then
    echo ""
  fi
}

# ════════════════════════════════════════════════════════════
#  ROLLBACK SYSTEM
# ════════════════════════════════════════════════════════════
#
#  The rollback log is an append-only list of undo commands.
#  Each line is a shell command that undoes one action.
#  On failure, run_rollback() replays them in reverse order.
#
#  rollback_push <undo_command>
#    Records one undo action.  Call immediately after any
#    state-changing run_cmd / run_shell / run_pkg.
#
#  run_rollback
#    Replays all recorded undo actions in reverse order.
#    Called automatically by the ERR trap.
#
rollback_push() {
  [[ "$DRY_RUN" == true ]] && { log_dry "[ROLLBACK PUSH] $*"; return 0; }
  [[ "$ROLLBACK_ENABLED" == false ]] && return 0
  mkdir -p "$(dirname "$ROLLBACK_LOG")"
  echo "$*" >> "$ROLLBACK_LOG"
  log_debug "Rollback queued: $*"
}

run_rollback() {
  [[ "$ROLLBACK_ENABLED" == false ]] && {
    log_warn "Rollback disabled — manual cleanup required."
    return
  }
  [[ ! -f "$ROLLBACK_LOG" ]] && {
    log_warn "No rollback log found — nothing to undo."
    return
  }

  echo ""
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${RED}${BOLD}  ROLLING BACK — undoing completed steps   ${RESET}"
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  # Read lines into array and replay in reverse
  local -a lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done < "$ROLLBACK_LOG"

  local total="${#lines[@]}"
  local i
  for (( i=total-1; i>=0; i-- )); do
    local cmd="${lines[$i]}"
    log_rollback "Undoing: ${cmd}"
    bash -c "$cmd" 2>/dev/null || log_warn "  Undo failed (may already be clean): ${cmd}"
  done

  # Remove rollback log after successful replay
  rm -f "$ROLLBACK_LOG"

  echo ""
  log_rollback "Rollback complete."
  echo ""
}

# Error trap — fires on any unhandled error when set -e is active
_on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  echo ""
  log_error "Installation failed at line ${line_no} (exit code ${exit_code})."
  run_rollback
  print_elapsed_total
  echo ""
  echo -e "  ${YELLOW}To retry from where you left off, run:${RESET}"
  echo -e "  ${BOLD}sudo bash $0 --resume${RESET}"
  echo ""
  exit "$exit_code"
}
trap '_on_error $LINENO' ERR

# ════════════════════════════════════════════════════════════
#  RESUME / CHECKPOINT SYSTEM
# ════════════════════════════════════════════════════════════
#
#  State file format (key=value, one per line):
#    completed_steps=step1,step2,...
#    INSTALL_PANEL=true
#    INSTALL_DAEMON=true
#    WEBSERVER=nginx
#    PHP_VERSION=8.2
#    ...  (all config vars needed to resume)
#
#  checkpoint_mark <step_name>
#    Call at the end of each major function.
#
#  checkpoint_done <step_name>
#    Returns 0 if the step was previously completed (skip it).
#    Returns 1 if the step needs to run.
#
state_init() {
  [[ "$DRY_RUN" == true ]] && return 0
  mkdir -p "$(dirname "$STATE_FILE")"
  [[ ! -f "$STATE_FILE" ]] && echo "completed_steps=" > "$STATE_FILE"
}

state_get() {
  local key="$1"
  [[ ! -f "$STATE_FILE" ]] && return 1
  grep "^${key}=" "$STATE_FILE" | cut -d= -f2- | head -1
}

state_set() {
  local key="$1" val="$2"
  [[ "$DRY_RUN" == true ]] && { log_dry "state_set ${key}=${val}"; return 0; }
  mkdir -p "$(dirname "$STATE_FILE")"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    # Update existing key (portable sed)
    sed -i "s|^${key}=.*|${key}=${val}|" "$STATE_FILE"
  else
    echo "${key}=${val}" >> "$STATE_FILE"
  fi
}

checkpoint_mark() {
  local step="$1"
  [[ "$DRY_RUN" == true ]] && { log_dry "checkpoint_mark ${step}"; return 0; }

  local current
  current=$(state_get "completed_steps" || echo "")
  if [[ -z "$current" ]]; then
    state_set "completed_steps" "$step"
  else
    # Avoid duplicates
    if ! echo "$current" | grep -qw "$step"; then
      state_set "completed_steps" "${current},${step}"
    fi
  fi
  log_debug "Checkpoint: ${step} marked complete"
}

checkpoint_done() {
  local step="$1"
  [[ "$RESUME_MODE" == false ]] && return 1
  [[ ! -f "$STATE_FILE" ]] && return 1

  local completed
  completed=$(state_get "completed_steps" || echo "")
  if echo "$completed" | grep -qw "$step"; then
    log_resume "$step"
    return 0
  fi
  return 1
}

# Restore config vars saved in state (for resume mode)
state_restore_config() {
  [[ "$RESUME_MODE" == false ]] && return 0
  [[ ! -f "$STATE_FILE" ]] && {
    log_error "No state file found at ${STATE_FILE} — cannot resume."
    log_error "Run without --resume to start a fresh installation."
    exit 1
  }

  log_section "Restoring Configuration from Previous Run"

  local vars=(
    INSTALL_PANEL INSTALL_DAEMON WEBSERVER PHP_VERSION
    PANEL_ORIGIN PANEL_PORT
    SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_ENABLED SMTP_USER SMTP_PASS SMTP_FROM
    BETTER_AUTH_SECRET
    ADMIN_NAME ADMIN_EMAIL ADMIN_PASS
    OS_ID OS_VERSION_ID OS_PRETTY PKG_MANAGER
    ARCH BUN_ARCH GO_ARCH
    PLYORDE_VERSION PLYORDE_BUILD_FROM_SOURCE
    PLYORDE_DB_NAME PLYORDE_DB_USER PLYORDE_DB_PASS
    PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS
    PUBLIC_IP
  )

  local restored=0
  for var in "${vars[@]}"; do
    local val
    val=$(state_get "$var" || true)
    if [[ -n "$val" ]]; then
      export "$var"="$val"
      log_debug "Restored: ${var}=${val}"
      (( restored++ )) || true
    fi
  done

  log_done "Restored ${restored} config vars from state."

  local completed
  completed=$(state_get "completed_steps" || echo "")
  if [[ -n "$completed" ]]; then
    log_info "Previously completed steps: ${completed//,/  }"
  fi
}

# Save all config vars to state after collection
state_save_config() {
  [[ "$DRY_RUN" == true ]] && { log_dry "state_save_config (all vars)"; return 0; }

  local vars=(
    INSTALL_PANEL INSTALL_DAEMON WEBSERVER PHP_VERSION
    PANEL_ORIGIN PANEL_PORT
    SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_ENABLED SMTP_USER SMTP_FROM
    BETTER_AUTH_SECRET
    ADMIN_NAME ADMIN_EMAIL
    OS_ID OS_VERSION_ID OS_PRETTY PKG_MANAGER
    ARCH BUN_ARCH GO_ARCH
    PLYORDE_VERSION PLYORDE_BUILD_FROM_SOURCE
    PLYORDE_DB_NAME PLYORDE_DB_USER PLYORDE_DB_PASS
    PANEL_DB_NAME PANEL_DB_USER PANEL_DB_PASS
    PUBLIC_IP
  )

  # Note: passwords are saved to state (same protection as .env / config.toml)
  # chmod 600 the state file
  for var in "${vars[@]}"; do
    local val="${!var:-}"
    [[ -n "$val" ]] && state_set "$var" "$val"
  done

  # Save passwords separately (they may contain special chars — base64 encode)
  for secret_var in SMTP_PASS ADMIN_PASS PLYORDE_DB_PASS PANEL_DB_PASS; do
    local val="${!secret_var:-}"
    if [[ -n "$val" ]]; then
      state_set "${secret_var}" "$(printf '%s' "$val" | base64 -w0)"
    fi
  done

  chmod 600 "$STATE_FILE" 2>/dev/null || true
  log_debug "Config saved to state file."
}

# Decode base64-encoded secrets from state
state_restore_secrets() {
  [[ "$RESUME_MODE" == false ]] && return 0
  for secret_var in SMTP_PASS ADMIN_PASS PLYORDE_DB_PASS PANEL_DB_PASS; do
    local encoded
    encoded=$(state_get "$secret_var" || true)
    if [[ -n "$encoded" ]]; then
      export "$secret_var"="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || echo "$encoded")"
      log_debug "Secret restored: ${secret_var}"
    fi
  done
}

# ── Command execution wrappers ───────────────────────────────
run_cmd() {
  local desc="$1"; shift
  log_debug "CMD: $*"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "${desc}"
    log_dry "  → would run: $*"
    return 0
  fi
  "$@"
}

run_shell() {
  local desc="$1"; shift
  local cmd="$1"
  log_debug "SHELL: ${cmd}"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "${desc}"
    log_dry "  → would run: bash -c '${cmd}'"
    return 0
  fi
  bash -c "$cmd"
}

run_pkg() {
  log_debug "PKG INSTALL: $*"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "apt-get install -y -qq $*"
    return 0
  fi
  apt-get install -y -qq "$@"
  # Record rollback: remove every package we just installed
  for pkg in "$@"; do
    rollback_push "apt-get remove -y -qq '${pkg}' 2>/dev/null || true"
  done
}

run_mysql() {
  local desc="$1"
  local sql="$2"
  log_debug "MYSQL: ${sql}"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "${desc}"
    log_dry "  → SQL: ${sql}"
    return 0
  fi
  mysql -u root <<< "$sql"
}

run_systemctl() {
  local verb="$1" unit="$2"
  log_debug "SYSTEMCTL: ${verb} ${unit}"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "systemctl ${verb} ${unit}"
    return 0
  fi
  systemctl "$verb" "$unit" "${@:3}"
}

write_file() {
  local desc="$1" path="$2" content="$3"
  log_debug "WRITE FILE: ${path}"
  if [[ "$DRY_RUN" == true ]]; then
    log_dry "${desc}"
    log_dry "  → would write ${path} (${#content} bytes)"
    return 0
  fi
  printf '%s' "$content" > "$path"
  rollback_push "rm -f '${path}'"
}

# ── Root check ───────────────────────────────────────────────
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log_warn "Not running as root, but --dry-run is active — continuing simulation."
    else
      abort "This installer must be run as root.  Try: sudo bash $0"
    fi
  fi
}

# ── Pre-flight checks ────────────────────────────────────────
preflight_checks() {
  log_section "Pre-flight Checks"

  local free_kb
  free_kb=$(df --output=avail / | tail -1)
  local free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "$free_gb" -lt 2 ]]; then
    log_warn "Low disk space: ~${free_gb} GB free on /  (2 GB recommended)"
  else
    log_done "Disk space: ~${free_gb} GB free on /"
  fi

  local mem_kb
  mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local mem_mb=$(( mem_kb / 1024 ))
  if [[ "$mem_mb" -lt 512 ]]; then
    log_warn "Low RAM: ${mem_mb} MB  (512 MB minimum recommended)"
  else
    log_done "Memory: ${mem_mb} MB RAM"
  fi

  log_step "Checking internet connectivity..."
  if curl -fsSL --max-time 5 https://github.com > /dev/null 2>&1; then
    log_done "Internet connectivity: OK (reached github.com)"
  else
    if [[ "$DRY_RUN" == true ]]; then
      log_warn "Cannot reach github.com — dry-run continuing anyway"
    else
      abort "No internet access — cannot reach github.com"
    fi
  fi

  if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
      log_warn "Port 80 is already in use — the web server install may conflict"
    else
      log_done "Port 80: available"
    fi
  fi

  if ! command -v systemctl &>/dev/null; then
    log_warn "systemctl not found — systemd services will not be registered"
  else
    log_done "systemd: present"
  fi

  log_done "Pre-flight checks complete."
}

# ── Bootstrap ────────────────────────────────────────────────
bootstrap_deps() {
  local missing=()
  command -v curl  &>/dev/null || missing+=(curl)
  command -v git   &>/dev/null || missing+=(git)
  command -v gpg   &>/dev/null || missing+=(gpg)
  command -v unzip &>/dev/null || missing+=(unzip)
  command -v jq    &>/dev/null || missing+=(jq)
  command -v iproute2 &>/dev/null || missing+=(iproute2)

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_step "Bootstrapping missing tools: ${missing[*]}"
    if [[ "$DRY_RUN" == true ]]; then
      log_dry "apt-get update -qq"
      log_dry "apt-get install -y -qq ca-certificates ${missing[*]}"
    else
      apt-get update -qq
      apt-get install -y -qq ca-certificates "${missing[@]}"
    fi
    log_done "Bootstrap tools ready."
  else
    log_debug "All bootstrap tools already present."
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

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would query: https://api.github.com/repos/plywp/plyorde/releases"
    PLYORDE_VERSION="v0.0.0-dryrun"
    PLYORDE_BUILD_FROM_SOURCE=false
    log_dry "Simulated release tag: ${PLYORDE_VERSION}"
    return 0
  fi

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

    if [[ "$DRY_RUN" == true ]]; then
      log_dry "Would prompt for reinstall/uninstall/exit — skipping in dry-run."
      log_dry "Simulating choice: 1 (Reinstall)"
      return 0
    fi

    echo -e "  ${BOLD}What would you like to do?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Reinstall ${DIM}(stops services, wipes files, keeps databases)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Uninstall PlyWP"
    echo -e "  ${CYAN}[3]${RESET} Upgrade ${DIM}(stops services, upgrades files, keeps databases)${RESET}"
    echo -e "  ${CYAN}[0]${RESET} Exit"
    echo ""
    ask "Enter choice [0-3]:"
    read -r EXIST_CHOICE || EXIST_CHOICE=""
    case "$EXIST_CHOICE" in
      1)
        log_step "Removing existing installation..."
        for svc in plyorde plywp-panel; do
          run_systemctl stop    "$svc"    2>/dev/null || true
          run_systemctl disable "$svc"    2>/dev/null || true
          run_cmd "Remove service file" rm -f "/etc/systemd/system/${svc}.service"
        done
        run_cmd "Reload systemd" systemctl daemon-reload
        run_cmd "Remove binaries" rm -f /usr/local/bin/plyorde /usr/local/bin/bun
        run_cmd "Remove dirs"    rm -rf /opt/plyorde /etc/plyorde /var/www/plywp-panel
        run_cmd "Remove nginx vhost" rm -f \
          /etc/nginx/sites-enabled/plywp.conf \
          /etc/nginx/sites-available/plywp.conf
        run_cmd "Remove Caddyfile" rm -f /etc/caddy/Caddyfile
        id plywp &>/dev/null && run_cmd "Remove plywp user" userdel -r plywp 2>/dev/null || true
        # Clear state for fresh install
        rm -f "$STATE_FILE" "$ROLLBACK_LOG"
        log_done "Existing installation removed — proceeding with fresh install."
        ;;
      2)
        run_uninstall
        exit 0
        ;;
      3)
        log_step "Upgrading existing installation..."
        if [[ "$found_panel" == true ]]; then
          run_cmd "Upgrade plywp-panel" cd /var/www/plywp-panel && git pull && bun install
          run_cmd "Restart plywp-panel" systemctl restart plywp-panel
        fi
        if [[ "$found_daemon" == true ]]; then
            PLYORDE_SRC_DIR="/opt/plyorde"
            PLYORDE_CONFIG_DIR="/etc/plyorde"
            PLYORDE_BIN="/usr/local/bin/plyorde"

            run_cmd "Create config dir" mkdir -p "$PLYORDE_CONFIG_DIR"

            if [[ "${PLYORDE_BUILD_FROM_SOURCE:-false}" == true ]]; then
              log_step "Cloning plyorde source..."
              run_cmd "Remove old source" rm -rf "$PLYORDE_SRC_DIR"
              run_cmd "Clone plyorde" git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
              log_step "Building plyorde binary (Go)..."
              run_shell "Build plyorde" "cd ${PLYORDE_SRC_DIR} && /usr/local/go/bin/go build -o ${PLYORDE_BIN} ."
              log_done "Plyorde built from source."
            else
              DOWNLOAD_URL="https://github.com/plywp/plyorde/releases/download/${PLYORDE_VERSION}/${GO_ARCH}-linux-plyorde"
              log_step "Downloading plyorde ${PLYORDE_VERSION} from: ${DOWNLOAD_URL}"
              log_debug "Binary URL: ${DOWNLOAD_URL}"

              local url_ok=false
              if [[ "$DRY_RUN" == false ]]; then
                curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL" && url_ok=true || true
              else
                log_dry "HEAD check: ${DOWNLOAD_URL}"
                url_ok=true
              fi

              if [[ "$url_ok" == true ]]; then
                run_shell "Download plyorde binary" "curl -fsSL ${DOWNLOAD_URL} -o ${PLYORDE_BIN}"
                run_cmd "Make plyorde executable" chmod +x "$PLYORDE_BIN"
                log_done "Plyorde binary downloaded."
              else
                log_warn "Pre-built binary not available for ${GO_ARCH} — building from source."
                PLYORDE_BUILD_FROM_SOURCE=true
                install_go
                run_cmd "Remove old source" rm -rf "$PLYORDE_SRC_DIR"
                run_cmd "Clone plyorde" git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
                run_shell "Build plyorde" "cd ${PLYORDE_SRC_DIR} && /usr/local/go/bin/go build -o ${PLYORDE_BIN} ."
                log_done "Plyorde built from source (fallback)."
              fi
            fi

            run_cmd "Make plyorde executable" chmod +x "$PLYORDE_BIN"
            run_cmd "Restart plyorde" systemctl restart plyorde
        fi
        log_done "Upgrade completed."
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

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would prompt for install choice — auto-selecting 1 (full stack) for dry-run."
    INSTALL_PANEL=true
    INSTALL_DAEMON=true
    return 0
  fi

  ask "Enter choice [0-4]:"
  read -r INSTALL_CHOICE || INSTALL_CHOICE=""

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

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would prompt for web server — auto-selecting nginx for dry-run."
    WEBSERVER="nginx"
    return 0
  fi

  ask "Enter choice [1-2]:"
  read -r WS_CHOICE || WS_CHOICE=""
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

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would prompt for PHP version — auto-selecting PHP 8.2 for dry-run."
    PHP_VERSION="8.2"
    return 0
  fi

  ask "Enter choice [1-3]:"
  read -r PHP_CHOICE || PHP_CHOICE=""
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

  if [[ "$DRY_RUN" == true ]]; then
    PANEL_ORIGIN="http://${PUBLIC_IP}"
    PANEL_PORT="3000"
    SMTP_HOST="smtp.example.com"
    SMTP_PORT="587"
    SMTP_SECURE="false"
    SMTP_ENABLED="false"
    SMTP_USER=""
    SMTP_PASS="[redacted]"
    SMTP_FROM="no-reply@example.com"
    BETTER_AUTH_SECRET="[would-be-generated-48-char-secret]"
    log_dry "Panel config auto-filled for dry-run:"
    log_dry "  ORIGIN=${PANEL_ORIGIN}  PORT=${PANEL_PORT}"
    log_dry "  SMTP_HOST=${SMTP_HOST}:${SMTP_PORT}  SMTP_ENABLED=${SMTP_ENABLED}"
    return 0
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
  read -rs SMTP_PASS || SMTP_PASS=""; echo ""

  ask_default "SMTP from address" "no-reply@example.com"; SMTP_FROM="$REPLY"

  BETTER_AUTH_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48; echo)
  log_done "BETTER_AUTH_SECRET generated (48 chars)."
}

collect_admin_credentials() {
  log_section "Admin Account"
  echo -e "  ${DIM}Create the first admin user for the PlyWP panel.${RESET}"
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    ADMIN_NAME="Admin"
    ADMIN_EMAIL="admin@example.com"
    ADMIN_PASS="[dry-run-placeholder]"
    log_dry "Admin credentials auto-filled: name=${ADMIN_NAME}  email=${ADMIN_EMAIL}"
    return 0
  fi

  ask_default "Admin name"  "Admin";       ADMIN_NAME="$REPLY"
  ask_default "Admin email" "admin@example.com"; ADMIN_EMAIL="$REPLY"

  while true; do
    echo -e -n "  ${CYAN}?${RESET}  Admin password (min 8 chars): "
    read -rs ADMIN_PASS || ADMIN_PASS=""; echo ""
    if [[ ${#ADMIN_PASS} -lt 8 ]]; then
      log_warn "Password too short — must be at least 8 characters."
    else
      echo -e -n "  ${CYAN}?${RESET}  Confirm password: "
      read -rs ADMIN_PASS2 || ADMIN_PASS2=""; echo ""
      if [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]]; then
        log_warn "Passwords do not match — try again."
      else
        break
      fi
    fi
  done
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
  if [[ "${PLYORDE_BUILD_FROM_SOURCE:-false}" == false ]]; then
    log_info "Plyorde   : ${PLYORDE_VERSION} (pre-built binary)"
  else
    log_info "Plyorde   : built from source (Go required)"
  fi
  log_info "Rollback  : ${ROLLBACK_ENABLED}"
  log_info "State file: ${STATE_FILE}"

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    log_dry "DRY RUN — skipping confirmation prompt, proceeding with simulation."
    return 0
  fi

  echo ""
  ask "Proceed with installation? [y/N]:"
  read -r CONFIRM || CONFIRM=""
  [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] || abort "Installation cancelled."
}

# ── Calculate how many steps will actually run ───────────────
calculate_progress_total() {
  local total=4  # base: base_deps, sys_tools, mariadb, configure_dbs
  if [[ "${INSTALL_DAEMON:-false}" == true ]]; then
    total=$(( total + 3 ))  # php, wpcli, plyorde
    total=$(( total + 1 ))  # webserver
    [[ "${PLYORDE_BUILD_FROM_SOURCE:-false}" == true ]] && total=$(( total + 1 ))  # go
  fi
  if [[ "${INSTALL_PANEL:-false}" == true ]]; then
    total=$(( total + 1 ))  # panel
    [[ "${INSTALL_DAEMON:-false}" == false ]] && total=$(( total + 1 ))  # webserver (panel-only)
  fi
  echo "$total"
}

# ════════════════════════════════════════════════════════════
#  INSTALL FUNCTIONS
# ════════════════════════════════════════════════════════════

install_base_dependencies() {
  checkpoint_done "install_base_dependencies" && return 0

  progress_step "Base dependencies"
  log_section "Installing Base Dependencies"
  if [[ "$DRY_RUN" == false ]]; then
    apt-get update -qq
  else
    log_dry "apt-get update -qq"
  fi
  run_pkg \
    ca-certificates curl gnupg lsb-release \
    git unzip tar wget sudo systemd openssl
  log_done "Base dependencies ready."

  checkpoint_mark "install_base_dependencies"
}

install_system_tools() {
  checkpoint_done "install_system_tools" && return 0

  progress_step "System tools"
  log_section "Installing System Tools"
  run_pkg \
    acl procps cron at \
    util-linux e2fsprogs findutils coreutils passwd
  log_done "System tools ready."

  checkpoint_mark "install_system_tools"
}

install_mariadb() {
  checkpoint_done "install_mariadb" && return 0

  progress_step "MariaDB"
  log_section "Installing MariaDB"
  if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
    log_info "MariaDB/MySQL already present — skipping install."
  else
    run_pkg mariadb-server mariadb-client
    rollback_push "systemctl stop mariadb 2>/dev/null || true"
    rollback_push "apt-get remove -y -qq mariadb-server mariadb-client 2>/dev/null || true"
  fi
  run_systemctl enable mariadb
  run_systemctl start  mariadb
  log_done "MariaDB running."

  checkpoint_mark "install_mariadb"
}

configure_databases() {
  checkpoint_done "configure_databases" && return 0

  progress_step "Databases"
  log_section "Configuring Databases"

  # Only generate new passwords if not already set (fresh install)
  PLYORDE_DB_NAME="${PLYORDE_DB_NAME:-plyorde}"
  PLYORDE_DB_USER="${PLYORDE_DB_USER:-plyorde}"
  PANEL_DB_NAME="${PANEL_DB_NAME:-panel}"
  PANEL_DB_USER="${PANEL_DB_USER:-panel}"

  if [[ -z "${PLYORDE_DB_PASS:-}" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      PLYORDE_DB_PASS="[dry-run-db-pass]"
    else
      PLYORDE_DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; echo)
    fi
  fi

  if [[ -z "${PANEL_DB_PASS:-}" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      PANEL_DB_PASS="[dry-run-db-pass]"
    else
      PANEL_DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; echo)
    fi
  fi

  log_debug "PLYORDE_DB_PASS length: ${#PLYORDE_DB_PASS}"
  log_debug "PANEL_DB_PASS length: ${#PANEL_DB_PASS}"

  local sql
  sql="CREATE DATABASE IF NOT EXISTS \`${PLYORDE_DB_NAME}\`;
CREATE USER IF NOT EXISTS '${PLYORDE_DB_USER}'@'localhost' IDENTIFIED BY '${PLYORDE_DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${PLYORDE_DB_USER}'@'localhost' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS \`${PANEL_DB_NAME}\`;
CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${PANEL_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PANEL_DB_NAME}\`.* TO '${PANEL_DB_USER}'@'localhost';
FLUSH PRIVILEGES;"

  run_mysql "Create databases and users" "$sql"

  # Rollback: drop databases and users
  rollback_push "mysql -u root -e \"DROP DATABASE IF EXISTS \\\`${PLYORDE_DB_NAME}\\\`; DROP DATABASE IF EXISTS \\\`${PANEL_DB_NAME}\\\`; DROP USER IF EXISTS '${PLYORDE_DB_USER}'@'localhost'; DROP USER IF EXISTS '${PANEL_DB_USER}'@'localhost'; FLUSH PRIVILEGES;\" 2>/dev/null || true"

  log_done "DB '${PLYORDE_DB_NAME}' (plyorde) and '${PANEL_DB_NAME}' (panel) created."

  checkpoint_mark "configure_databases"
}

install_php() {
  checkpoint_done "install_php" && return 0

  progress_step "PHP ${PHP_VERSION}"
  log_section "Installing PHP ${PHP_VERSION}"

  if [[ "$OS_ID" == "ubuntu" ]]; then
    if ! grep -rq "ondrej/php\|launchpadcontent.net/ondrej" /etc/apt/sources.list.d/ 2>/dev/null; then
      log_step "Adding ondrej/php PPA (manual key import — avoids Launchpad API timeouts)..."
      local codename
      codename=$(lsb_release -sc)
      if [[ "$DRY_RUN" == false ]]; then
        gpg --no-default-keyring \
            --keyring /usr/share/keyrings/ondrej-php.gpg \
            --keyserver hkp://keyserver.ubuntu.com:80 \
            --recv-keys 14AA40EC0831756756D7F66C4F4EA0AAE5267A6C
        echo "deb [signed-by=/usr/share/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${codename} main" \
          > /etc/apt/sources.list.d/ondrej-php.list
        apt-get update -qq
        rollback_push "rm -f /etc/apt/sources.list.d/ondrej-php.list /usr/share/keyrings/ondrej-php.gpg"
      else
        log_dry "gpg --recv-keys 14AA40EC0831756756D7F66C4F4EA0AAE5267A6C (ondrej/php)"
        log_dry "echo 'deb [...] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${codename} main' > ondrej-php.list"
        log_dry "apt-get update -qq"
      fi
    fi
  else
    if ! grep -r "sury" /etc/apt/sources.list.d/ &>/dev/null; then
      run_shell "Add Sury PHP GPG key" \
        "curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg"
      run_shell "Add Sury PHP repo" \
        "echo 'deb https://packages.sury.org/php/ $(lsb_release -sc) main' > /etc/apt/sources.list.d/sury-php.list"
      if [[ "$DRY_RUN" == false ]]; then
        apt-get update -qq
        rollback_push "rm -f /etc/apt/sources.list.d/sury-php.list /etc/apt/trusted.gpg.d/sury-php.gpg"
      else
        log_dry "apt-get update -qq"
      fi
    fi
  fi

  run_pkg \
    "php${PHP_VERSION}-cli"     "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-mysql"   "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-zip"     "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-intl"

  run_systemctl enable "php${PHP_VERSION}-fpm"
  run_systemctl start  "php${PHP_VERSION}-fpm"
  rollback_push "systemctl stop 'php${PHP_VERSION}-fpm' 2>/dev/null || true"
  log_done "PHP ${PHP_VERSION} + php-fpm running."

  checkpoint_mark "install_php"
}

install_wpcli() {
  checkpoint_done "install_wpcli" && return 0

  progress_step "WP-CLI"
  log_section "Installing WP-CLI"
  if command -v wp &>/dev/null; then
    log_info "WP-CLI already installed — skipping."
  else
    run_shell "Download WP-CLI" \
      "curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp"
    run_cmd "Make WP-CLI executable" chmod +x /usr/local/bin/wp
    rollback_push "rm -f /usr/local/bin/wp"
  fi
  log_done "WP-CLI installed."

  checkpoint_mark "install_wpcli"
}

install_go() {
  checkpoint_done "install_go" && return 0

  progress_step "Go toolchain"
  log_section "Installing Go Toolchain"
  if command -v go &>/dev/null; then
    log_info "Go already installed ($(go version | awk '{print $3}')) — skipping."
    checkpoint_mark "install_go"
    return
  fi

  GO_VERSION="1.24.4"
  GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  log_step "Downloading Go ${GO_VERSION}..."
  run_shell "Download Go tarball" \
    "curl -fsSL https://go.dev/dl/${GO_TAR} -o /tmp/${GO_TAR}"
  run_cmd "Remove old Go" rm -rf /usr/local/go
  run_cmd "Extract Go" tar -C /usr/local -xzf "/tmp/${GO_TAR}"
  run_cmd "Remove Go tarball" rm -f "/tmp/${GO_TAR}"

  run_shell "Add Go to PATH" \
    "echo 'export PATH=\$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh"
  export PATH="$PATH:/usr/local/go/bin"

  rollback_push "rm -rf /usr/local/go /etc/profile.d/go.sh"
  log_done "Go ${GO_VERSION} installed."

  checkpoint_mark "install_go"
}

install_bun() {
  BUN_BIN="/usr/local/bin/bun"

  if [[ -x "$BUN_BIN" ]]; then
    log_info "Bun already installed ($("$BUN_BIN" --version)) — skipping."
    return
  fi

  log_step "Downloading and installing Bun..."
  run_shell "Run Bun installer" "curl -fsSL https://bun.sh/install | bash"

  if [[ "$DRY_RUN" == false ]]; then
    if [[ ! -x "${HOME}/.bun/bin/bun" ]]; then
      abort "Bun installer did not produce ${HOME}/.bun/bin/bun — aborting."
    fi
    run_cmd "Copy bun to /usr/local/bin" cp "${HOME}/.bun/bin/bun" /usr/local/bin/bun
    run_cmd "Set bun permissions"        chmod 755 /usr/local/bin/bun
    rollback_push "rm -f /usr/local/bin/bun"
    log_done "Bun $(/usr/local/bin/bun --version) installed → /usr/local/bin/bun"
  else
    log_dry "cp ~/.bun/bin/bun /usr/local/bin/bun && chmod 755 /usr/local/bin/bun"
  fi

  export PATH="/usr/local/bin:${PATH}"
}

# BUG FIX #1 & #2: function definition syntax fixed (added () and fixed call site)
setup_webserver_template() {
  log_section "Setting Up Web Server Template For: ${WEBSERVER}"
  mkdir -p /var/template
  if [[ "$WEBSERVER" == "nginx" ]]; then
    write_file "Write nginx template" /var/template/nginx.conf.tmp \
      "$(curl -fsSL https://github.com/plywp/plyorde/raw/refs/heads/main/src/webconfig/templates/nginx.conf.tmpl)"
  elif [[ "$WEBSERVER" == "caddy" ]]; then
    write_file "Write caddy template" /var/template/caddy.conf.tmp \
      "$(curl -fsSL https://github.com/plywp/plyorde/raw/refs/heads/main/src/webconfig/templates/caddy.conf.tmpl)"
  fi
  rollback_push "rm -rf /var/template"
}

install_webserver() {
  checkpoint_done "install_webserver" && return 0

  progress_step "Web server (${WEBSERVER})"
  log_section "Installing Web Server: ${WEBSERVER}"

  if [[ "$WEBSERVER" == "nginx" ]]; then
    run_pkg nginx
    run_systemctl enable nginx
    run_systemctl start  nginx
    rollback_push "systemctl stop nginx 2>/dev/null || true"
    rollback_push "apt-get remove -y -qq nginx 2>/dev/null || true"
  else
    run_pkg apt-transport-https
    run_shell "Add Caddy GPG key" \
      "curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/caddy-stable.gpg"
    run_shell "Add Caddy repo" \
      "echo 'deb [trusted=yes] https://apt.fury.io/caddy/ /' > /etc/apt/sources.list.d/caddy-fury.list"
    if [[ "$DRY_RUN" == false ]]; then
      apt-get update -qq
      rollback_push "rm -f /etc/apt/sources.list.d/caddy-fury.list /etc/apt/trusted.gpg.d/caddy-stable.gpg"
    else
      log_dry "apt-get update -qq"
    fi
    run_pkg caddy
    run_systemctl enable caddy
    run_systemctl start  caddy
    rollback_push "systemctl stop caddy 2>/dev/null || true"
    rollback_push "apt-get remove -y -qq caddy 2>/dev/null || true"
  fi

  log_done "${WEBSERVER} installed and running."

  # BUG FIX #2: plain function call, no trailing ()
  setup_webserver_template

  checkpoint_mark "install_webserver"
}

install_plyorde() {
  checkpoint_done "install_plyorde" && return 0

  progress_step "Plyorde daemon"
  log_section "Installing Plyorde Daemon"

  PLYORDE_SRC_DIR="/opt/plyorde"
  PLYORDE_CONFIG_DIR="/etc/plyorde"
  PLYORDE_BIN="/usr/local/bin/plyorde"

  run_cmd "Create config dir" mkdir -p "$PLYORDE_CONFIG_DIR"
  rollback_push "rm -rf '${PLYORDE_CONFIG_DIR}'"

  if [[ "${PLYORDE_BUILD_FROM_SOURCE:-false}" == true ]]; then
    log_step "Cloning plyorde source..."
    run_cmd "Remove old source" rm -rf "$PLYORDE_SRC_DIR"
    run_cmd "Clone plyorde" git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
    rollback_push "rm -rf '${PLYORDE_SRC_DIR}'"
    log_step "Building plyorde binary (Go)..."
    run_shell "Build plyorde" "cd ${PLYORDE_SRC_DIR} && /usr/local/go/bin/go build -o ${PLYORDE_BIN} ."
    log_done "Plyorde built from source."
  else
    DOWNLOAD_URL="https://github.com/plywp/plyorde/releases/download/${PLYORDE_VERSION}/${GO_ARCH}-linux-plyorde"
    log_step "Downloading plyorde ${PLYORDE_VERSION} from: ${DOWNLOAD_URL}"
    log_debug "Binary URL: ${DOWNLOAD_URL}"

    local url_ok=false
    if [[ "$DRY_RUN" == false ]]; then
      curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL" && url_ok=true || true
    else
      log_dry "HEAD check: ${DOWNLOAD_URL}"
      url_ok=true
    fi

    if [[ "$url_ok" == true ]]; then
      run_shell "Download plyorde binary" "curl -fsSL ${DOWNLOAD_URL} -o ${PLYORDE_BIN}"
      run_cmd "Make plyorde executable" chmod +x "$PLYORDE_BIN"
      rollback_push "rm -f '${PLYORDE_BIN}'"
      log_done "Plyorde binary downloaded."
    else
      log_warn "Pre-built binary not available for ${GO_ARCH} — building from source."
      PLYORDE_BUILD_FROM_SOURCE=true
      install_go
      run_cmd "Remove old source" rm -rf "$PLYORDE_SRC_DIR"
      run_cmd "Clone plyorde" git clone --depth=1 https://github.com/plywp/plyorde.git "$PLYORDE_SRC_DIR"
      rollback_push "rm -rf '${PLYORDE_SRC_DIR}'"
      run_shell "Build plyorde" "cd ${PLYORDE_SRC_DIR} && /usr/local/go/bin/go build -o ${PLYORDE_BIN} ."
      log_done "Plyorde built from source (fallback)."
    fi
  fi

  run_cmd "Make plyorde executable" chmod +x "$PLYORDE_BIN"

  local config_content
  config_content="# Plyorde configuration — generated by plywp-installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Restart plyorde after editing: systemctl restart plyorde

[database]
  host     = \"127.0.0.1\"
  port     = 3306
  name     = \"${PLYORDE_DB_NAME}\"
  user     = \"${PLYORDE_DB_USER}\"
  password = \"${PLYORDE_DB_PASS}\"

[daemon]
  listen = \"127.0.0.1:8743\"

[webserver]
  type = \"${WEBSERVER}\"

[php]
  version = \"${PHP_VERSION}\""

  write_file "Write plyorde config.toml" "${PLYORDE_CONFIG_DIR}/config.toml" "$config_content"
  log_done "Config written → ${PLYORDE_CONFIG_DIR}/config.toml"

  INIT_SQL="${PLYORDE_SRC_DIR}/init_db.sql"
  if [[ -f "$INIT_SQL" ]]; then
    log_step "Importing plyorde database schema..."
    # BUG FIX #3: run_shell result captured separately so && / || are reliable
    if run_shell "Import schema" "mysql -u root ${PLYORDE_DB_NAME} < ${INIT_SQL}"; then
      log_done "Schema imported."
    else
      log_warn "Schema import failed — run manually: mysql -u root ${PLYORDE_DB_NAME} < ${INIT_SQL}"
    fi
  else
    log_debug "No init_db.sql found at ${INIT_SQL} — skipping schema import."
  fi

  local service_content
  service_content="[Unit]
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
WantedBy=multi-user.target"

  write_file "Write plyorde systemd service" /etc/systemd/system/plyorde.service "$service_content"
  rollback_push "systemctl stop plyorde 2>/dev/null || true; systemctl disable plyorde 2>/dev/null || true; rm -f /etc/systemd/system/plyorde.service; systemctl daemon-reload"

  run_cmd "Reload systemd" systemctl daemon-reload
  run_systemctl enable plyorde
  mkdir -p /var/lib/plyorde

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

  checkpoint_mark "install_plyorde"
}

install_panel() {
  checkpoint_done "install_panel" && return 0

  progress_step "PlyWP Panel"
  log_section "Installing PlyWP Panel"

  PANEL_DIR="/var/www/plywp-panel"
  PANEL_USER="plywp"

  if ! id "$PANEL_USER" &>/dev/null; then
    run_cmd "Create plywp user" useradd --system --shell /usr/sbin/nologin \
      --home-dir "$PANEL_DIR" --create-home "$PANEL_USER"
    rollback_push "userdel -r plywp 2>/dev/null || true"
    log_done "System user '${PANEL_USER}' created."
  else
    log_debug "User '${PANEL_USER}' already exists."
  fi

  log_step "Cloning PlyWP Panel source..."
  if [[ -d "${PANEL_DIR}/.git" ]]; then
    run_cmd "Pull panel source" git -C "$PANEL_DIR" pull --quiet
    log_done "Panel source updated."
  else
    run_cmd "Remove old panel dir" rm -rf "$PANEL_DIR"
    run_cmd "Clone panel" git clone --depth=1 https://github.com/plywp/panel.git "$PANEL_DIR"
    rollback_push "rm -rf '${PANEL_DIR}'"
    log_done "Panel source cloned → ${PANEL_DIR}"
  fi
  run_cmd "Set panel dir ownership" chown -R "${PANEL_USER}:${PANEL_USER}" "$PANEL_DIR"

  install_bun

  log_step "Writing .env..."
  local env_content
  env_content="# PlyWP Panel — generated by plywp-installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
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
SMTP_FROM=\"${SMTP_FROM}\""

  write_file "Write .env" "${PANEL_DIR}/.env" "$env_content"
  run_cmd "Restrict .env permissions"  chmod 600 "${PANEL_DIR}/.env"
  run_cmd "Set .env ownership"         chown "${PANEL_USER}:${PANEL_USER}" "${PANEL_DIR}/.env"
  log_done ".env written (mode 600)."

  log_step "Installing panel dependencies (bun install --frozen-lockfile)..."
  run_shell "bun install" "cd ${PANEL_DIR} && bun install --frozen-lockfile"
  log_done "Dependencies installed."

  log_step "Configuring adapter-node..."
  if run_shell "sv add adapter-node" \
    "cd ${PANEL_DIR} && bun x --yes sv add 'sveltekit-adapter=adapter:node' --install bun"; then
    log_done "adapter-node configured."
  else
    log_warn "sv add sveltekit-adapter failed — build may fail; check svelte.config.js"
  fi

  log_step "Running Drizzle database migrations (bun run db:migrate)..."
  if run_shell "Drizzle migrate" "cd ${PANEL_DIR} && bun run db:migrate"; then
    log_done "Drizzle migrations applied."
  else
    log_warn "Migrations may have failed — re-run: cd ${PANEL_DIR} && bun run db:migrate"
  fi

  log_step "Building panel for production (bun run build)..."
  run_shell "bun build" "cd ${PANEL_DIR} && bun run build"
  run_cmd "Set panel ownership" chown -R "${PANEL_USER}:${PANEL_USER}" "$PANEL_DIR"
  log_done "Panel built → ${PANEL_DIR}/build/"

  local svc_content
  svc_content="[Unit]
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
WantedBy=multi-user.target"

  write_file "Write plywp-panel service" /etc/systemd/system/plywp-panel.service "$svc_content"
  rollback_push "systemctl stop plywp-panel 2>/dev/null || true; systemctl disable plywp-panel 2>/dev/null || true; rm -f /etc/systemd/system/plywp-panel.service; systemctl daemon-reload"

  run_cmd "Reload systemd" systemctl daemon-reload
  run_systemctl enable plywp-panel

  if [[ "$DRY_RUN" == false ]]; then
    if systemctl start plywp-panel; then
      log_done "plywp-panel service started."
    else
      log_warn "Panel service failed to start — check: journalctl -u plywp-panel"
    fi
  else
    log_dry "systemctl start plywp-panel"
  fi

  configure_vhost
  create_admin_user

  checkpoint_mark "install_panel"
}

create_admin_user() {
  log_section "Creating Admin User"
  log_step "Running bun run add-user..."

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would run: cd ${PANEL_DIR} && bun run add-user '${ADMIN_NAME}' '${ADMIN_EMAIL}' '[password]' admin '${ADMIN_NAME} org'"
    return 0
  fi

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
    local nginx_conf
    nginx_conf="server {
    listen 80;
    server_name _;

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
}"

    write_file "Write nginx vhost" /etc/nginx/sites-available/plywp.conf "$nginx_conf"
    rollback_push "rm -f /etc/nginx/sites-available/plywp.conf /etc/nginx/sites-enabled/plywp.conf"

    run_cmd "Remove default nginx site" rm -f /etc/nginx/sites-enabled/default
    run_cmd "Enable plywp nginx site" \
      ln -sf /etc/nginx/sites-available/plywp.conf /etc/nginx/sites-enabled/plywp.conf

    if [[ "$DRY_RUN" == false ]]; then
      if nginx -t; then
        systemctl reload nginx && log_done "Nginx reverse proxy configured."
      else
        log_warn "Nginx config test failed — check: nginx -t"
      fi
    else
      log_dry "nginx -t && systemctl reload nginx"
    fi

  else
    local CADDY_HOST="${PANEL_ORIGIN#http://}"
    CADDY_HOST="${CADDY_HOST#https://}"

    write_file "Write Caddyfile" /etc/caddy/Caddyfile \
"${CADDY_HOST} {
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}"
    rollback_push "rm -f /etc/caddy/Caddyfile"

    if [[ "$DRY_RUN" == false ]]; then
      if systemctl reload caddy; then
        log_done "Caddy reverse proxy configured."
      else
        log_warn "Caddy reload failed — check: /etc/caddy/Caddyfile"
      fi
    else
      log_dry "systemctl reload caddy"
    fi
  fi
}

run_uninstall() {
  log_section "Uninstalling PlyWP"

  if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would prompt for uninstall confirmation — simulating yes in dry-run."
  else
    ask "Stop & remove plyorde, panel service, files, and vhosts? [y/N]:"
    read -r UNCONFIRM || UNCONFIRM=""
    [[ "${UNCONFIRM,,}" == "y" || "${UNCONFIRM,,}" == "yes" ]] \
      || { echo "Aborted."; return; }
  fi

  for svc in plyorde plywp-panel; do
    run_systemctl stop    "$svc"
    run_systemctl disable "$svc"
    run_cmd "Remove service file" rm -f "/etc/systemd/system/${svc}.service"
  done
  run_cmd "Reload systemd" systemctl daemon-reload

  run_cmd "Remove plyorde binary" rm -f /usr/local/bin/plyorde
  run_cmd "Remove plyorde dirs"   rm -rf /opt/plyorde /etc/plyorde /var/www/plywp-panel
  run_cmd "Remove nginx vhost"    rm -f /etc/nginx/sites-enabled/plywp.conf \
                                         /etc/nginx/sites-available/plywp.conf
  run_cmd "Remove Caddyfile"      rm -f /etc/caddy/Caddyfile

  if [[ "$DRY_RUN" == false ]]; then
    systemctl reload nginx 2>/dev/null || true
    systemctl reload caddy 2>/dev/null || true
    id plywp &>/dev/null && userdel plywp 2>/dev/null || true
    rm -f "$STATE_FILE" "$ROLLBACK_LOG"
  else
    log_dry "systemctl reload nginx/caddy"
    log_dry "userdel plywp"
    log_dry "rm -f ${STATE_FILE} ${ROLLBACK_LOG}"
  fi

  log_done "PlyWP removed."
  log_warn "Databases were NOT dropped. To remove them:"
  echo -e "  ${DIM}mysql -u root -e \"DROP DATABASE panel; DROP DATABASE plyorde;\"${RESET}"
  echo -e "  ${DIM}mysql -u root -e \"DROP USER 'panel'@'localhost'; DROP USER 'plyorde'@'localhost';\"${RESET}"
}

print_summary() {
  log_section "Installation Complete"

  progress_done

  print_elapsed_total

  echo ""
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}${BOLD}DRY RUN finished — no changes were made to this system.${RESET}"
    echo ""
  fi

  if [[ "${INSTALL_PANEL:-false}" == true ]]; then
    echo -e "  ${GREEN}Panel URL  :${RESET} ${BOLD}${PANEL_ORIGIN}${RESET}"
    echo -e "  ${DIM}Panel DB   : ${PANEL_DB_NAME}  user: ${PANEL_DB_USER}  pass: ${PANEL_DB_PASS}${RESET}"
    echo -e "  ${DIM}Panel .env : /var/www/plywp-panel/.env${RESET}"
    echo -e "  ${DIM}Panel logs : journalctl -u plywp-panel -f${RESET}"
    echo ""
  fi

  if [[ "${INSTALL_DAEMON:-false}" == true ]]; then
    echo -e "  ${GREEN}Plyorde    :${RESET} ${BOLD}installed — awaiting configuration${RESET}"
    echo -e "  ${DIM}Plyorde DB : ${PLYORDE_DB_NAME}  user: ${PLYORDE_DB_USER}  pass: ${PLYORDE_DB_PASS}${RESET}"
    echo -e "  ${DIM}Plyorde cfg: /etc/plyorde/config.toml${RESET}"
    echo -e "  ${DIM}Daemon logs: journalctl -u plyorde -f${RESET}"
    echo ""
  fi

  if [[ -n "$LOG_FILE" ]]; then
    echo -e "  ${DIM}Install log: ${LOG_FILE}${RESET}"
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

  # Clean up state + rollback log on successful completion
  if [[ "$DRY_RUN" == false ]]; then
    rm -f "$STATE_FILE" "$ROLLBACK_LOG"
    log_info "State files cleaned up."
  fi
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
main() {
  parse_args "$@"

  print_banner
  setup_logging
  setup_debug

  check_root
  state_init

  # ── Resume mode: restore config, skip completed steps ──────
  if [[ "$RESUME_MODE" == true ]]; then
    state_restore_config
    state_restore_secrets
  fi

  bootstrap_deps
  detect_os
  check_arch
  fetch_latest_release

  preflight_checks

  detect_existing_installation

  # ── Interactive menus (only if not resuming) ────────────────
  if [[ "$RESUME_MODE" == false ]]; then
    main_menu
    webserver_menu
    [[ "${INSTALL_DAEMON:-false}" == true ]] && php_version_menu
    [[ "${INSTALL_PANEL:-false}"  == true ]] && collect_panel_config
    [[ "${INSTALL_PANEL:-false}"  == true ]] && collect_admin_credentials
    confirm_install
    state_save_config
  else
    log_info "Resume mode: skipping interactive menus."
    log_info "Install plan: panel=${INSTALL_PANEL:-false}  daemon=${INSTALL_DAEMON:-false}  webserver=${WEBSERVER:-nginx}"
  fi

  # ── Init progress bar ───────────────────────────────────────
  local total_steps
  total_steps=$(calculate_progress_total)
  echo ""
  log_section "Installation Progress"
  progress_init "$total_steps"

  # ── Run steps ───────────────────────────────────────────────
  install_base_dependencies
  install_system_tools
  install_mariadb
  configure_databases

  if [[ "${INSTALL_DAEMON:-false}" == true ]]; then
    install_php
    install_wpcli
    install_webserver
    [[ "${PLYORDE_BUILD_FROM_SOURCE:-false}" == true ]] && install_go
    install_plyorde
  fi

  if [[ "${INSTALL_PANEL:-false}" == true ]]; then
    [[ "${INSTALL_DAEMON:-false}" == false ]] && install_webserver
    install_panel
  fi

  print_summary
}

main "$@"
