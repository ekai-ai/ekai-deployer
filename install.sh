#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Ekai deployer
# Usage: curl -fsSL https://raw.githubusercontent.com/ekai-ai/ekai-deployer/refs/heads/main/install.sh | bash
# ──────────────────────────────────────────────────────────────────────────────

# Only line to touch when merging dev -> staging -> main — everything below
# derives from it, so PORTAL_URL and BASE_URL can't drift out of sync with
# each other the way they did before.
DEPLOYER_BRANCH="staging"  # dev | staging | main
if [ "$DEPLOYER_BRANCH" = "main" ]; then
  PORTAL_URL="https://licensing.ekai.ai"
else
  PORTAL_URL="https://${DEPLOYER_BRANCH}.licensing.ekai.ai"
fi
CALLBACK_PORT="${EKAI_CALLBACK_PORT:-9999}"
BASE_URL="https://raw.githubusercontent.com/ekai-ai/ekai-deployer/refs/heads/${DEPLOYER_BRANCH}"
COMPOSE_URL="${BASE_URL}/local-deploy/docker-compose.yml"
ENV_EXAMPLE_URL="${BASE_URL}/local-deploy/.env.example"
ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"
LOCAL_DIR="ekai-local-deployment" # relative to cwd; holds the local deploy's compose + env
NORTHWIND_DIR_URL="${BASE_URL}/local-deploy/northwind"  # load.sh + setup.sql
NORTHWIND_DB="northwind"
NORTHWIND_USER="northwind"
NORTHWIND_PASSWORD="northwind"
PG_CONTAINER="ekai-postgres"
GCP_REPO_TARBALL_URL="https://github.com/ekai-ai/terraform-google-ekai/archive/refs/heads/main.tar.gz"
GCP_DEPLOY_DIR="terraform-google-ekai" # relative to cwd, downloaded below
AWS_REPO_TARBALL_URL="https://github.com/ekai-ai/terraform-aws-ekai/archive/refs/heads/main.tar.gz"
AWS_DEPLOY_DIR="terraform-aws-ekai" # relative to cwd, downloaded below

# When run via `curl ... | bash`, this script's own stdin is a pipe, not a
# real terminal -- and with the whole process tree rooted that way, deeply
# nested children (self-deploy.sh's own terraform calls, two levels down in
# the cloud deploy paths) can lose proper foreground-terminal association
# and silently suppress their live progress output, even though fd 1
# nominally still points at the terminal (confirmed live: a targeted apply
# ran and completed correctly with zero output reaching the terminal).
# Re-exec from a freshly-downloaded real file instead of continuing to run
# from the pipe -- a real file as $0 restores normal job-control/foreground
# behavior for everything this script goes on to run. Re-downloads rather
# than trying to recover the remainder of the current pipe, since bash may
# have already buffered an unknown amount of this script's own source out
# of it by this point.
if [ ! -t 0 ] && [ -z "${EKAI_INSTALL_REEXEC:-}" ]; then
  SELF_COPY=$(mktemp /tmp/ekai-install-XXXXXX.sh)
  if curl -fsSL "${BASE_URL}/install.sh" -o "$SELF_COPY"; then
    chmod +x "$SELF_COPY"
    EKAI_INSTALL_REEXEC=1 exec bash "$SELF_COPY" "$@" < /dev/tty
  else
    echo "Warning: could not re-download install.sh for a clean re-exec; continuing from the pipe as-is (live progress output may be suppressed for nested Terraform runs)." >&2
    rm -f "$SELF_COPY"
  fi
fi


# ── Colours ───────────────────────────────────────────────────────────────────
bold=$(tput bold 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
cyan=$(tput setaf 6 2>/dev/null || true)

info()    { echo "${cyan}${bold}→${reset} $*"; }
success() { echo "${green}${bold}✓${reset} $*"; }
warn()    { echo "${yellow}${bold}!${reset} $*"; }
error()   { echo "${red}${bold}✗${reset} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── OS check ──────────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Native Windows is not supported. Please run this script inside WSL2." ;;
  *)
    warn "Unrecognised OS: $(uname -s) — proceeding anyway." ;;
esac

# ── Dependency checks ─────────────────────────────────────────────────────────
# need() records a missing tool instead of dying immediately, so a batch of
# independent checks (e.g. all GCP prereqs) can run to completion and report
# everything that's missing — each with how to install it — in one go, rather
# than stopping at the first. Each miss is warned inline (with remediation) as
# it's found; fail_if_missing_tools just dies afterward without repeating it.
# Usage: need <tool> [remediation text]
_missing_tools=""
need() {
  local tool="$1"
  local remediation="${2:-Please install it and re-run.}"
  command -v "$tool" &>/dev/null || {
    warn "Required tool not found: ${tool}. ${remediation}"
    _missing_tools="${_missing_tools} ${tool}"
    return 1
  }
  return 0
}

fail_if_missing_tools() {
  [ -z "$_missing_tools" ] || die "Missing required tools:${_missing_tools}. Install them (see above) and re-run."
}

reset_missing_tools() { _missing_tools=""; }

# ── Auto-install ──────────────────────────────────────────────────────────────
detect_pkg_manager() {
  if [ "$(uname -s)" = "Darwin" ]; then
    command -v brew &>/dev/null && { echo "brew"; return; }
  else
    command -v apt-get &>/dev/null && { echo "apt-get"; return; }
    command -v dnf &>/dev/null && { echo "dnf"; return; }
    command -v yum &>/dev/null && { echo "yum"; return; }
  fi
  echo "none"
}

# Per-tool, per-package-manager install commands for the GCP deploy path
# (gcloud, terraform, kubectl, gke-gcloud-auth-plugin, jq, dig). Binary name
# doesn't always match package name (e.g. `dig` ships in `dnsutils`/`bind-utils`),
# and gcloud/terraform aren't in the default apt/yum repos, so each needs its
# own real install command rather than a generic "<pkg-manager> install <tool>".
# Usage: install_cmd_for <tool> <pkg-manager> — prints the command, or nothing
# if there's no known auto-install path for that combination.
install_cmd_for() {
  local tool="$1" mgr="$2"
  case "${tool}:${mgr}" in
    gcloud:brew)
      echo "brew install --cask google-cloud-sdk" ;;
    gcloud:apt-get)
      echo 'curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list && sudo apt-get update && sudo apt-get install -y google-cloud-cli' ;;
    gcloud:dnf|gcloud:yum)
      echo "sudo ${mgr} install -y google-cloud-cli" ;;
    terraform:brew)
      echo "brew tap hashicorp/tap && brew install hashicorp/tap/terraform" ;;
    terraform:apt-get)
      echo 'curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list && sudo apt-get update && sudo apt-get install -y terraform' ;;
    terraform:dnf|terraform:yum)
      echo "sudo ${mgr} install -y -q dnf-plugins-core 2>/dev/null; sudo ${mgr} config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo; sudo ${mgr} install -y terraform" ;;
    kubectl:brew)
      echo "brew install kubectl" ;;
    kubectl:apt-get|kubectl:dnf|kubectl:yum)
      # Installed as a gcloud component instead of via the package manager —
      # simpler than adding the separate Kubernetes apt/yum repo, and this
      # box already needs gcloud for the GCP path anyway.
      echo "gcloud components install kubectl --quiet" ;;
    gke-gcloud-auth-plugin:*)
      echo "gcloud components install gke-gcloud-auth-plugin --quiet" ;;
    jq:brew)
      echo "brew install jq" ;;
    jq:apt-get)
      echo "sudo apt-get install -y jq" ;;
    jq:dnf|jq:yum)
      echo "sudo ${mgr} install -y jq" ;;
    dig:brew)
      echo "brew install bind" ;;
    dig:apt-get)
      echo "sudo apt-get install -y dnsutils" ;;
    dig:dnf|dig:yum)
      echo "sudo ${mgr} install -y bind-utils" ;;
    docker-compose:apt-get)
      # docker-compose-plugin lives in Docker's own repo, not the distro's, so
      # add it first — the distro's docker.io package is what leaves a machine
      # with a daemon but no Compose in the first place.
      echo 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg && echo "deb [signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list && sudo apt-get update && sudo apt-get install -y docker-compose-plugin' ;;
    docker-compose:dnf|docker-compose:yum)
      echo "sudo ${mgr} config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && sudo ${mgr} install -y docker-compose-plugin" ;;
  esac
}

# Offers to auto-install every tool in $_missing_tools, once, with a single
# y/N prompt — rather than asking per-tool, which would be tedious when
# several are missing at once (the common case on a fresh machine). Anything
# that installs successfully is removed from $_missing_tools; anything that
# fails, or that the user declines, is left for the caller's existing
# fail_if_missing_tools / manual-instructions path to report.
offer_auto_install_missing_tools() {
  [ -n "$_missing_tools" ] || return 0

  local mgr
  mgr=$(detect_pkg_manager)
  if [ "$mgr" = "none" ]; then
    warn "No supported package manager found (brew/apt-get/dnf/yum) — can't auto-install."
    return 0
  fi

  echo "" >/dev/tty
  echo "${bold}Missing tools:${reset}${_missing_tools}" >/dev/tty
  printf "Try to install these automatically now (using %s)? [Y/n]: " "$mgr" >/dev/tty
  local answer
  read -r answer </dev/tty
  case "$answer" in
    n|N|no|No) return 0 ;;
  esac

  local still_missing="" tool cmd
  for tool in $_missing_tools; do
    cmd=$(install_cmd_for "$tool" "$mgr")
    if [ -z "$cmd" ]; then
      warn "No known auto-install command for ${tool} on ${mgr}."
      still_missing="${still_missing} ${tool}"
      continue
    fi
    info "Installing ${tool}: ${cmd}"
    if eval "$cmd" </dev/tty && command -v "$tool" &>/dev/null; then
      success "${tool} installed"
    else
      error "Failed to install ${tool}."
      still_missing="${still_missing} ${tool}"
    fi
  done

  _missing_tools="$still_missing"
}

need curl "Install it with: brew install curl (macOS) or apt-get install curl / yum install curl (Linux)."
fail_if_missing_tools

# Prompts for "<prompt>: " and keeps re-asking "<prompt> (required): " until
# something non-empty comes back, then writes it into the caller's variable.
# Pass -s to read silently (for secrets) -- it still re-prompts the same
# way, just without echoing input, and prints the newline -s itself
# swallows once a value is accepted. Replaces the same ~10-line
# while-read-or-reprompt block that used to be copy-pasted once per field
# across deploy_gcp/deploy_aws.
ask_required() {
  local __var="$1" __prompt="$2" __silent="${3:-}" __value=""
  printf "%s: " "$__prompt" >/dev/tty
  while [ -z "$__value" ]; do
    if [ "$__silent" = "-s" ]; then
      read -rs __value </dev/tty
      [ -n "$__value" ] || printf "\n%s (required): " "$__prompt" >/dev/tty
    else
      read -r __value </dev/tty
      [ -n "$__value" ] || printf "%s (required): " "$__prompt" >/dev/tty
    fi
  done
  [ "$__silent" = "-s" ] && echo "" >/dev/tty
  printf -v "$__var" '%s' "$__value"
}

# ── Step 1: get deploy token via browser login ─────────────────────────────────
get_token_via_browser() {
  local callback_url="http://localhost:${CALLBACK_PORT}/token"
  local portal_page="${PORTAL_URL}/install?callback=${callback_url}"

  # Spin up a Python HTTP server that stays alive across multiple connections.
  # It writes the received token to a temp file and exits once it has one.
  local token_file
  token_file=$(mktemp)

  # Redirected: this runs in the background for the rest of the function, and
  # get_token_via_browser's stdout is captured wholesale by the caller — an
  # unexpected traceback or warning from this process would otherwise land in
  # the token value instead of the terminal.
  python3 - "$CALLBACK_PORT" "$token_file" <<'PYEOF' &>/dev/null &
import sys, json, threading
from http.server import HTTPServer, BaseHTTPRequestHandler

port      = int(sys.argv[1])
token_file = sys.argv[2]
received  = threading.Event()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass  # silence access log
    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length)
        self.send_response(200)
        self._cors()
        self.end_headers()
        try:
            tok = json.loads(body).get('exchangeToken', '')
        except Exception:
            tok = ''
        if tok:
            open(token_file, 'w').write(tok)
            received.set()
            threading.Thread(target=srv.shutdown, daemon=True).start()
    def _cors(self):
        self.send_header('Access-Control-Allow-Origin',  '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

srv = HTTPServer(('127.0.0.1', port), Handler)
srv.timeout = 180
received.wait(timeout=0)  # non-blocking
srv.serve_forever()
PYEOF
  local py_pid=$!

  # Make sure the callback server is always killed, even on Ctrl+C or early exit,
  # so it doesn't linger holding CALLBACK_PORT. A custom INT/TERM trap suppresses
  # bash's default terminate-on-signal behavior, so exit explicitly here too.
  trap 'kill "$py_pid" 2>/dev/null || true; rm -f "$token_file"; exit 130' INT TERM
  trap 'kill "$py_pid" 2>/dev/null || true; rm -f "$token_file"' EXIT

  # Give Python a moment to bind the port before opening the browser
  sleep 1

  echo "" >/dev/tty
  info "Opening your browser to log in to the ekai portal…" >/dev/tty
  echo "  ${bold}${portal_page}${reset}" >/dev/tty
  echo "" >/dev/tty

  # get_token_via_browser's stdout is captured wholesale by the caller (as
  # the deploy token), so every one of these must have its own stdout/stderr
  # redirected away — e.g. linux `xdg-open` prints "Opening in existing browser
  # session." to stdout, which would otherwise land in the token value.
  if command -v open &>/dev/null; then
    open "$portal_page" &>/dev/null
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$portal_page" &>/dev/null
  elif command -v wslview &>/dev/null; then
    # WSL2: xdg-open needs a desktop environment stock WSL2 doesn't have.
    # wslview (from the `wslu` package) hands the URL to the Windows side instead.
    wslview "$portal_page" &>/dev/null
  elif command -v powershell.exe &>/dev/null; then
    # WSL2 fallback when wslu isn't installed — powershell.exe is on PATH by
    # default and can launch the Windows default browser directly.
    powershell.exe /c start "$portal_page" &>/dev/null
  else
    warn "Could not open browser automatically. Please open the URL above manually." >/dev/tty
  fi

  info "Waiting for token from portal (listening on port ${CALLBACK_PORT})…" >/dev/tty
  echo "  If the browser doesn't open, visit the URL above to log in — the" >/dev/tty
  echo "  page will send the token here automatically once you do." >/dev/tty
  echo "" >/dev/tty

  # Give it 3 minutes to receive the token.
  local exchange_token=""
  local deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    exchange_token=$(cat "$token_file" 2>/dev/null || true)
    if [ -n "$exchange_token" ]; then
      break
    fi
    sleep 1
  done
  kill "$py_pid" 2>/dev/null || true
  rm -f "$token_file"
  trap - EXIT INT TERM

  if [ -z "$exchange_token" ]; then
    die "Did not receive a token from the portal within 3 minutes. Make sure you logged in at the URL above, then re-run the installer."
  fi

  # Redeem the exchange token for the deploy token + email
  info "Redeeming token…" >/dev/tty
  local redeem_response
  # || true: under set -e, a failing command inside a bare var=$(...)
  # assignment kills the script right there -- the die below would never
  # run otherwise (confirmed: without this, a curl failure here exits
  # silently, no message, before the empty-token check ever executes).
  redeem_response=$(curl -s -X POST "${PORTAL_URL}/api/auth/exchange-token/redeem" \
    -H "Content-Type: application/json" \
    -d "{\"exchangeToken\":\"${exchange_token}\"}" || true)

  local deploy_token
  local user_email
  deploy_token=$(printf '%s' "$redeem_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['apiKey'])" 2>/dev/null || true)
  user_email=$(printf '%s' "$redeem_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null || true)

  if [ -z "$deploy_token" ]; then
    die "Failed to redeem token. Please re-run the installer and try again."
  fi
  if [ -z "$user_email" ]; then
    warn "Could not read your email back from the portal response -- account seeding will be skipped for the local Docker path (cloud deploys aren't affected)." >/dev/tty
  fi

  printf '%s\n%s' "$deploy_token" "$user_email"
}

# ── Step 2: deployment type ───────────────────────────────────────────────────
ask_deployment_type() {
  echo "" >/dev/tty
  echo "${bold}Where do you want to deploy ekai?${reset}" >/dev/tty
  echo "  1) Local  (Docker on this machine)" >/dev/tty
  echo "  2) Cloud  (Kubernetes via Helm)" >/dev/tty
  echo "" >/dev/tty
  printf "Enter choice [1/2]: " >/dev/tty
  read -r choice </dev/tty
  case "$choice" in
    1|local|Local)   echo "local" ;;
    2|cloud|Cloud)   echo "cloud" ;;
    *)               die "Invalid choice: $choice" ;;
  esac
}

# ── Local deployment ──────────────────────────────────────────────────────────
detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    arm64|aarch64)  echo "linux/arm64" ;;
    x86_64|amd64)   echo "linux/amd64" ;;
    *)
      warn "Unknown architecture: $arch — defaulting to linux/amd64" >/dev/tty
      echo "linux/amd64"
      ;;
  esac
}

# v2 required: the compose file is Compose Spec, which v1 can't run.
# String not array — bash 3.2 (macOS) errors on empty array + set -u.
COMPOSE=""

# Remediation text for a missing/too-old Compose, using this box's package
# manager — same install_cmd_for pattern as the other prereqs.
compose_remediation() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "Install/update Docker Desktop, which bundles Compose v2 — https://www.docker.com/products/docker-desktop/"
    return
  fi
  local cmd
  cmd=$(install_cmd_for docker-compose "$(detect_pkg_manager)")
  if [ -n "$cmd" ]; then
    echo "Install it with: ${cmd}"
  else
    echo "Install it — see https://docs.docker.com/compose/install/"
  fi
}

detect_compose() {
  if docker compose version &>/dev/null; then
    COMPOSE="docker compose"
    return
  fi

  if command -v docker-compose &>/dev/null; then
    local v
    v=$(docker-compose version --short 2>/dev/null || echo "")
    case "$v" in
      2.*|v2.*) COMPOSE="docker-compose"; return ;;
      *) die "Docker Compose ${v:-v1} is too old to run this stack (v2+ required). $(compose_remediation)" ;;
    esac
  fi

  die "Docker Compose is not installed (v2+ required). $(compose_remediation)"
}

check_local_requirements() {
  reset_missing_tools
  need docker "Install Docker Desktop from https://www.docker.com/products/docker-desktop/ (on WSL2, install it on Windows and enable WSL2 integration for this distro in Docker Desktop → Settings → Resources → WSL Integration)."
  fail_if_missing_tools

  # Docker running? This gates every other check below (they all shell out
  # to `docker info`), so it still has to fail fast on its own.
  docker info &>/dev/null || die "Docker is not running. Please start Docker Desktop and re-run."
  success "Docker is running"

  # Compose must be resolved before any $COMPOSE call below.
  detect_compose
  success "Docker Compose: $($COMPOSE version --short 2>/dev/null || echo "$COMPOSE")"

  # Remaining checks are independent of each other — run them all and only
  # report the disk-space failure (the one that's fatal) after the rest.
  local disk_ok=1

  # Available disk space >= 3 GB (in the Docker VM / current mount)
  local free_kb
  free_kb=$(df -Pk . | awk 'NR==2 {print $4}')
  local free_gb=$(( free_kb / 1024 / 1024 ))
  if [ "$free_gb" -lt 3 ]; then
    error "Not enough disk space: ${free_gb} GB free, 3 GB required."
    disk_ok=0
  else
    success "Disk space: ${free_gb} GB free"
  fi

  # CPUs available to Docker >= 6
  local cpus
  cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  if [ "$cpus" -lt 6 ]; then
    warn "Docker has ${cpus} CPU(s) available; 6 recommended. Performance may be degraded."
    warn "Increase CPU allocation in Docker Desktop → Settings → Resources."
  else
    success "Docker CPUs: ${cpus}"
  fi

  # Memory available to Docker >= 8 GB
  local mem_bytes
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  local mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if [ "$mem_gb" -lt 8 ]; then
    warn "Docker has ${mem_gb} GB RAM allocated; 8 GB recommended."
    warn "Increase memory allocation in Docker Desktop → Settings → Resources."
  else
    success "Docker memory: ${mem_gb} GB"
  fi

  [ "$disk_ok" -eq 1 ] || die "Free up disk space and re-run."
}

# ── Northwind sample data ─────────────────────────────────────────────────────
# The work lives in local-deploy/northwind/{load.sh,setup.sql}; this file only
# prompts, fetches them and runs load.sh.
NORTHWIND_LOADED=0

# Existing local install = our postgres container exists (running or stopped).
local_install_exists() {
  command -v docker &>/dev/null || return 1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"
}

# y/N prompt on the tty. $2 = default answer (y|n).
ask_yes_no() {
  local prompt="$1" default="${2:-n}" answer hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  printf "%s %s " "$prompt" "$hint" >/dev/tty
  read -r answer </dev/tty
  answer="${answer:-$default}"
  case "$answer" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# Runs load.sh with the given subcommand (exists|load) from a temp dir.
run_northwind() {
  local dir rc=0
  dir=$(mktemp -d)
  curl -fsSL "${NORTHWIND_DIR_URL}/load.sh" -o "${dir}/load.sh" \
    && curl -fsSL "${NORTHWIND_DIR_URL}/setup.sql" -o "${dir}/setup.sql" \
    || { rm -rf "$dir"; die "Could not download the Northwind sample data scripts."; }
  bash "${dir}/load.sh" "$1" "$NORTHWIND_DB" "$NORTHWIND_USER" "$NORTHWIND_PASSWORD" || rc=$?
  rm -rf "$dir"
  return "$rc"
}

# $1 = "ask" (rerun: always prompt, default No) or "auto" (fresh install: load
# without a question). An already-existing northwind DB always prompts, since
# loading replaces everything in it.
maybe_load_northwind() {
  local mode="${1:-ask}"
  local choice="${EKAI_LOAD_SAMPLE_DATA:-}"
  case "$choice" in no|No|NO|false|0) info "Skipping Northwind sample data (EKAI_LOAD_SAMPLE_DATA=no)."; return 0 ;; esac

  # Stopped install (e.g. user said no to redeploy): don't hang waiting on it.
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER" \
    || die "${PG_CONTAINER} is not running. Start Ekai first (or choose to redeploy) and re-run."

  local exists=0
  run_northwind exists && exists=1
  if [ "$mode" = "ask" ] || [ "$exists" = "1" ]; then
    echo "" >/dev/tty
    echo "${bold}Northwind sample data${reset} is a demo dataset for trying Ekai without your own data." >/dev/tty
    echo "It goes into its own '${NORTHWIND_DB}' database, never into Ekai's own." >/dev/tty
    warn "If '${NORTHWIND_DB}' already exists, ALL of its contents (data and any schemas or dbt models you created there) will be overwritten." >/dev/tty
    case "$choice" in
      yes|Yes|YES|true|1) ;;
      *) ask_yes_no "Load the Northwind sample data?" n || { info "Skipping Northwind sample data."; return 0; } ;;
    esac
  fi
  run_northwind load || die "Northwind sample data load failed."
  NORTHWIND_LOADED=1
}

print_northwind_info() {
  [ "$NORTHWIND_LOADED" = "1" ] || return 0
  echo ""
  echo "${bold}Northwind sample data${reset} — add it with the Postgres connector:"
  echo "  Host:      ekai-postgres   (not localhost — Ekai connects from inside Docker)"
  echo "  Port:      5432"
  echo "  Database:  ${NORTHWIND_DB}"
  echo "  User:      ${NORTHWIND_USER}"
  echo "  Password:  ${NORTHWIND_PASSWORD}"
  echo "  Schema:    public"
  echo "  Use SSL:   off  (the bundled Postgres has no SSL)"
}

deploy_local() {
  local token="$1"
  local user_email="${2:-}"
  local is_rerun="${3:-0}"

  # Keep the compose file and .env in their own directory rather than scattering
  # them in the cwd. Entered before the disk-space check so `df .` measures the
  # mount we actually deploy onto.
  mkdir -p "$LOCAL_DIR"
  cd "$LOCAL_DIR"
  success "Using ${bold}$(pwd)${reset}"

  check_local_requirements

  local platform
  platform=$(detect_arch)
  success "Detected architecture: ${platform}"

  # Download the standalone compose file
  info "Downloading ${COMPOSE_FILE}…"
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE"  # commented out for local testing
  success "Downloaded ${COMPOSE_FILE}"

  # Bootstrap .env from example
  info "Downloading ${ENV_FILE}.example…"
  curl -fsSL "$ENV_EXAMPLE_URL" -o "${ENV_FILE}.example"  # commented out for local testing
  cp "${ENV_FILE}.example" "$ENV_FILE"                     # commented out for local testing
  success "Downloaded ${ENV_FILE}.example"

  # ekai-erd's bash sandbox requires the Landlock LSM (Linux 5.13+). That's a
  # kernel feature, not an architecture one — irrelevant to Intel vs Apple
  # Silicon — but Docker Desktop's VM (macOS/Windows) doesn't expose it to
  # containers regardless of host CPU. Only native Linux Docker Engine shares
  # the host kernel directly, so only keep the sandbox required there.
  local sandbox_required="true"
  if [ "$(uname -s)" != "Linux" ]; then
    sandbox_required="false"
    warn "Non-Linux host detected — Landlock sandbox is unavailable under Docker Desktop, disabling SANDBOX_REQUIRED."
  fi

  # Inject / update EKAI_DEPLOY_TOKEN, EKAI_LICENSING_PORTAL_URL,
  # DOCKER_PLATFORM, and SANDBOX_REQUIRED.
  local tmp
  tmp=$(mktemp)
  grep -v -E "^EKAI_DEPLOY_TOKEN=|^EKAI_LICENSING_PORTAL_URL=|^DOCKER_PLATFORM=|^SANDBOX_REQUIRED=" "$ENV_FILE" > "$tmp" || true
  {
    echo "EKAI_DEPLOY_TOKEN=${token}"
    echo "EKAI_LICENSING_PORTAL_URL=${PORTAL_URL}"
    echo "DOCKER_PLATFORM=${platform}"
    echo "SANDBOX_REQUIRED=${sandbox_required}"
  } >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  success "${ENV_FILE} updated (EKAI_DEPLOY_TOKEN + EKAI_LICENSING_PORTAL_URL + DOCKER_PLATFORM + SANDBOX_REQUIRED set)"

  # Pull images one at a time. --parallel is not available on all Compose
  # versions (e.g. 2.3.3), so pull each service individually instead — this
  # works everywhere and avoids bursting the registry's rate limit.
  echo ""
  info "Pulling images…"
  local svc
  for svc in $($COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config --services); do
    info "Pulling ${svc}…"
    $COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull "$svc"
  done

  # Bring up the stack
  echo ""
  info "Starting ekai with Docker Compose…"
  $COMPOSE -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate

  # Seed the user account if we have an email and it isn't already there.
  local user_exists=""
  if [ -n "$user_email" ] && [ "$is_rerun" = "1" ]; then
    user_exists=$(docker exec "$PG_CONTAINER" psql -U ekai -d ekaibackend -tAq \
      -c "SELECT 1 FROM \"Users\" WHERE email = '${user_email}' LIMIT 1;" 2>/dev/null || true)
  fi
  if [ "$user_exists" = "1" ]; then
    success "Account for ${user_email} already exists — skipping user seeding"
  elif [ -n "$user_email" ]; then
    info "Waiting for database migrations to complete…"
    until docker exec ekai-postgres psql -U ekai -d ekaibackend -c '\dt "Users"' 2>/dev/null | grep -q Users; do
      sleep 3
    done
    success "Database is ready"

    info "Seeding user account (${user_email})…"
    # -v email=... + :'email' lets psql quote the value itself, instead of us
    # dropping it into the SQL as a literal string.
    docker exec -i ekai-postgres psql -U ekai -d ekaibackend -v ON_ERROR_STOP=1 -v email="${user_email}" -q <<'SQL'
INSERT INTO "Users" (id, email, name, status, "roleId", "createdAt")
VALUES (gen_random_uuid(), :'email', :'email', 'active', 4, now())
ON CONFLICT (email) DO NOTHING;

INSERT INTO "UserCredentials" ("userId", password, "createdAt", "updatedAt")
SELECT id, NULL, now(), now() FROM "Users" WHERE email = :'email'
ON CONFLICT ("userId") DO NOTHING;

INSERT INTO "Tenants" (name, "subscriptionId", "createdById")
SELECT 'My Tenant', s.id, u.id
FROM "Subscription" s, "Users" u
WHERE s.name = 'Trial' AND u.email = :'email'
  AND NOT EXISTS (SELECT 1 FROM "Tenants" LIMIT 1);

INSERT INTO "TenantUsers" ("tenantId", "userId")
SELECT t.id, u.id
FROM "Tenants" t, "Users" u
WHERE u.email = :'email'
ORDER BY t.id
LIMIT 1
ON CONFLICT DO NOTHING;
SQL
    local seeded_email
    seeded_email=$(docker exec ekai-postgres psql -U ekai -d ekaibackend -tAq \
      -v email="${user_email}" -c "SELECT email FROM \"Users\" WHERE email = :'email' LIMIT 1;" 2>/dev/null || true)
    if [ "$seeded_email" = "$user_email" ]; then
      success "Account ready for ${user_email}"
    else
      die "User seeding failed for ${user_email} — account was not created in the database."
    fi
  fi

  if [ "$is_rerun" = "1" ]; then
    maybe_load_northwind ask
  else
    maybe_load_northwind auto
  fi

  echo ""
  success "Ekai is running!"
  echo ""
  echo "  ${bold}Ekai:${reset}   http://localhost:80"
  echo "  ${bold}Files:${reset}  $(pwd)"
  print_northwind_info
  echo ""
  echo "From ${bold}$(pwd)${reset}:"
  echo "To stop:   ${bold}${COMPOSE} -f ${COMPOSE_FILE} down${reset}"
  echo "To update: ${bold}for s in \$(${COMPOSE} -f ${COMPOSE_FILE} config --services); do ${COMPOSE} -f ${COMPOSE_FILE} pull \"\$s\"; done && ${COMPOSE} -f ${COMPOSE_FILE} up -d${reset}"
}

# ── Cloud deployment ──────────────────────────────────────────────────────────
ask_cloud_provider() {
  echo "" >/dev/tty
  echo "${bold}Which cloud provider?${reset}" >/dev/tty
  echo "  1) AWS" >/dev/tty
  echo "  2) Azure" >/dev/tty
  echo "  3) GCP" >/dev/tty
  echo "  4) Other (manual)" >/dev/tty
  echo "" >/dev/tty
  printf "Enter choice [1-4]: " >/dev/tty
  read -r choice </dev/tty
  case "$choice" in
    1|AWS|aws)    echo "aws" ;;
    2|Azure|azure) echo "azure" ;;
    3|GCP|gcp)    echo "gcp" ;;
    4|other|Other) echo "other" ;;
    *)            die "Invalid choice: $choice" ;;
  esac
}

check_cloud_cli() {
  local provider="$1"
  case "$provider" in
    aws)
      if command -v aws &>/dev/null; then
        success "AWS CLI found: $(aws --version 2>&1 | head -1)"
        info "Checking AWS credentials…"
        if aws sts get-caller-identity &>/dev/null; then
          success "AWS credentials valid"
          aws sts get-caller-identity
        else
          warn "AWS CLI found but not authenticated. Run: aws configure"
          return 1
        fi
      else
        warn "AWS CLI not found. Install it from https://aws.amazon.com/cli/"
        return 1
      fi
      ;;
    azure)
      if command -v az &>/dev/null; then
        success "Azure CLI found: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || az --version 2>&1 | head -1)"
        info "Checking Azure credentials…"
        if az account show &>/dev/null; then
          success "Azure credentials valid"
          az account show --query '{subscription:name, id:id}' -o table
        else
          warn "Azure CLI found but not authenticated. Run: az login"
          return 1
        fi
      else
        warn "Azure CLI not found. Install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        return 1
      fi
      ;;
    gcp)
      if command -v gcloud &>/dev/null; then
        success "gcloud CLI found: $(gcloud --version 2>/dev/null | head -1)"
        info "Checking GCP credentials…"
        if gcloud auth print-access-token &>/dev/null; then
          success "GCP credentials valid"
          gcloud config list account --format 'value(core.account)' 2>/dev/null
        else
          warn "gcloud found but not authenticated. Run: gcloud auth login"
          return 1
        fi
      else
        warn "gcloud CLI not found. Install it from https://cloud.google.com/sdk/docs/install (on Windows, install it inside WSL following the Linux instructions)"
        return 1
      fi
      ;;
  esac
  return 0
}

# Checks every tool the GCP deploy path needs (gcloud, terraform, kubectl,
# gke-gcloud-auth-plugin, jq, dig), offers to auto-install whatever's missing,
# and reports anything still missing afterward — all before asking any of
# deploy_gcp's project/region/env/dns_zone questions, so a failure here isn't
# discovered only after the user has already answered all of those.
check_gcp_tools() {
  reset_missing_tools
  need gcloud "Install it from https://cloud.google.com/sdk/docs/install (on Windows, install it inside WSL following the Linux instructions)."
  need terraform "Install it: see https://developer.hashicorp.com/terraform/install (on Windows, install it inside WSL following the Linux instructions)"
  # self-deploy.sh's cicd apply needs `kubectl` to auth against the GKE
  # cluster it just created — modern GKE requires this plugin for that
  # rather than gcloud's older built-in auth, and kubectl fails with a
  # cryptic error mid-deploy without it.
  need kubectl "Install it: see https://kubernetes.io/docs/tasks/tools/ (on Windows, install it inside WSL following the Linux instructions)"
  # gke-gcloud-auth-plugin is a gcloud component — installing it first
  # requires gcloud itself, so only attempt it once gcloud is confirmed
  # present (either found already, or just auto-installed above).
  if command -v gcloud &>/dev/null; then
    need gke-gcloud-auth-plugin "Install it with: gcloud components install gke-gcloud-auth-plugin"
  fi
  # self-deploy.sh itself needs `jq` to parse gcloud/kubectl JSON output.
  need jq "Install it with: brew install jq (macOS) or sudo apt install jq / sudo yum install jq (Linux) — on Windows, install it inside WSL following the Linux instructions."
  # self-deploy.sh polls DNS (via `dig`) to confirm the domain's name servers
  # have propagated before continuing.
  need dig "Install it with: brew install bind (macOS) or sudo apt install dnsutils / sudo yum install bind-utils (Linux) — on Windows, install it inside WSL following the Linux instructions."

  offer_auto_install_missing_tools

  # gke-gcloud-auth-plugin couldn't even be checked above if gcloud was
  # missing at that point — check it now if gcloud just got auto-installed.
  if command -v gcloud &>/dev/null && ! command -v gke-gcloud-auth-plugin &>/dev/null; then
    need gke-gcloud-auth-plugin "Install it with: gcloud components install gke-gcloud-auth-plugin"
    offer_auto_install_missing_tools
  fi
}

check_gcp_requirements() {
  check_gcp_tools
  fail_if_missing_tools
}

# Runs every independent GCP prerequisite check (tools, gcloud auth) in one
# pass and reports all failures together, instead of stopping at whichever
# check happens to run first.
check_gcp_prereqs() {
  local ok=1

  check_gcp_tools
  [ -z "$_missing_tools" ] || ok=0

  if command -v gcloud &>/dev/null; then
    success "gcloud CLI found: $(gcloud --version 2>/dev/null | head -1)"
    info "Checking GCP credentials…"
    if gcloud auth print-access-token &>/dev/null; then
      success "GCP credentials valid"
      gcloud config list account --format 'value(core.account)' 2>/dev/null
    else
      warn "gcloud found but not authenticated. Run: gcloud auth login"
      ok=0
    fi
  fi

  [ "$ok" -eq 1 ]
}

check_gcp_permissions() {
  local project_id="$1"
  # Permissions PERMISSIONS.md's 5 bootstrapping-identity roles resolve to
  # (self-deploy.sh runs API enables/SA creation/IAM grants/state bucket
  # setup under this identity, before ever touching Terraform):
  #   serviceusage.serviceUsageAdmin  -> serviceusage.services.enable
  #   iam.serviceAccountAdmin         -> iam.serviceAccounts.create
  #   iam.serviceAccountKeyAdmin      -> iam.serviceAccountKeys.create
  #   resourcemanager.projectIamAdmin -> resourcemanager.projects.setIamPolicy
  #   storage.admin                   -> storage.buckets.create
  #
  # `gcloud projects test-iam-permissions` isn't a real CLI command — only
  # the underlying testIamPermissions REST API is. Call it directly with
  # curl (already required) using a gcloud-minted access token, rather than
  # matching role names via get-iam-policy — that only sees direct role
  # bindings, while this reports the actual effective permission regardless
  # of whether it came from a direct role, a custom role, or a group/org
  # -level grant. Doesn't need jq itself (the response is simple enough to
  # parse with grep) even though jq is checked as a prereq elsewhere for
  # self-deploy.sh, which needs it once it's actually running.
  local access_token
  access_token=$(gcloud auth print-access-token 2>/dev/null || true)
  [ -n "$access_token" ] || die "No active gcloud access token. Run: gcloud auth login"

  # || true: a failing curl here would otherwise kill the script right at
  # this assignment under set -e, before the error-message check below ever
  # runs.
  local response
  response=$(curl -s -X POST \
    "https://cloudresourcemanager.googleapis.com/v3/projects/${project_id}:testIamPermissions" \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -d '{"permissions": [
      "serviceusage.services.enable",
      "iam.serviceAccounts.create",
      "iam.serviceAccountKeys.create",
      "resourcemanager.projects.setIamPolicy",
      "storage.buckets.create"
    ]}' || true)

  if echo "$response" | grep -q '"error"'; then
    error "GCP rejected the permission check for project ${project_id}:"
    echo "$response" >&2
    die "Check the project ID is correct and re-run."
  fi

  local granted
  granted=$(echo "$response" | grep -o '"[a-zA-Z0-9_.]*"' | tr -d '"' | grep -v '^permissions$' || true)

  local missing=""
  local have=""
  local perm
  for perm in serviceusage.services.enable iam.serviceAccounts.create \
              iam.serviceAccountKeys.create resourcemanager.projects.setIamPolicy \
              storage.buckets.create; do
    case "$granted" in
      *"$perm"*) have="${have}  ${perm}\n" ;;
      *) missing="${missing}  ${perm}\n" ;;
    esac
  done

  if [ -n "$missing" ]; then
    error "Your GCP identity is missing required permissions on ${project_id}:"
    printf '%b' "$missing" >&2
    if [ -n "$have" ]; then
      echo "Permissions it does have:" >&2
      printf '%b' "$have" >&2
    else
      echo "It has none of the required permissions." >&2
    fi
    die "See https://github.com/ekai-ai/terraform-google-ekai/blob/main/PERMISSIONS.md (\"Bootstrapping identity\") for the roles to grant, then re-run."
  fi
  success "GCP permissions verified on ${project_id}"
}

# Looks for local signs that a deploy was previously started for some env (a
# generated tfvars + an artifact that only shows up once self-deploy.sh is
# partway through -- GCP's deployer-key JSON, AWS's generated-secrets file --
# or a backend config). Catches a self-deploy.sh run that errored, timed out,
# or was interrupted partway, as well as a run that finished cleanly. Prints
# the candidate env name on stdout if found, empty otherwise. Deliberately
# doesn't try to tell those cases apart (e.g. by reading Terraform output) —
# the user already saw that run's logs and knows whether it succeeded better
# than any local-file/state heuristic could; this only surfaces that
# artifacts exist so they can choose to retry or start fresh.
detect_partial_deploy() {
  local deploy_dir="$1"
  local artifact_suffix="$2"  # "-deployer-key.json" (GCP) or "-generated-secrets.txt" (AWS)

  [ -d "$deploy_dir" ] || return 0
  local tfvars_dir="${deploy_dir}/env"
  [ -d "$tfvars_dir" ] || return 0

  # Most-recently-modified non-template tfvars file is our one candidate —
  # good enough for "did a previous run leave something behind", not meant
  # to handle multiple concurrent in-progress envs.
  local candidate
  candidate=$(ls -t "${tfvars_dir}"/*.tfvars 2>/dev/null | grep -v '/customer\.tfvars$' | head -1 || true)
  [ -n "$candidate" ] || return 0

  local env_name
  env_name=$(basename "$candidate" .tfvars)

  local artifact_file="${deploy_dir}/.self-deploy/${env_name}${artifact_suffix}"
  local backend_file="${tfvars_dir}/backend-${env_name}.tfbackend"

  # Artifact or backend config existing means self-deploy.sh got at least as
  # far as Step 2/3 — real signal something was attempted, not just a
  # tfvars file the user hand-edited and never ran. Note GCP's deployer key
  # is meant to be deleted after copying it somewhere safe (self-deploy.sh
  # says so at the end), so its absence alone doesn't mean anything — the
  # backend file check covers that case.
  [ -f "$artifact_file" ] || [ -f "$backend_file" ] || return 0

  echo "$env_name"
}

deploy_gcp() {
  local token="$1"

  echo "" >/dev/tty
  local gcp_project_id
  ask_required gcp_project_id "GCP project ID"

  check_gcp_permissions "$gcp_project_id"

  printf "GCP region [us-east1]: " >/dev/tty
  local gcp_region
  read -r gcp_region </dev/tty
  gcp_region="${gcp_region:-us-east1}"

  echo "" >/dev/tty
  warn "The environment name becomes part of every GCP resource this creates — it must be unique per deployment, and 13 characters or fewer (GCP service account IDs cap the room this leaves)." >/dev/tty
  local gcp_env
  while :; do
    printf "Environment name: " >/dev/tty
    read -r gcp_env </dev/tty
    if [ -z "$gcp_env" ]; then
      printf "Environment name is required: " >/dev/tty
    elif [ "$gcp_env" = "customer" ]; then
      warn "\"customer\" is reserved (it's the template file itself) — pick a different environment name." >/dev/tty
    elif [ "${#gcp_env}" -gt 13 ]; then
      printf "Environment name must be 13 characters or fewer (got %d): " "${#gcp_env}" >/dev/tty
    else
      break
    fi
  done

  echo "" >/dev/tty
  info "dns_zone is the domain (or subdomain) you control DNS for — Ekai creates a Cloud DNS zone under it, which you'll delegate to Google's nameservers at your registrar afterward." >/dev/tty
  local gcp_dns_zone
  ask_required gcp_dns_zone "DNS zone (e.g. example.com)"

  echo "" >/dev/tty
  info "acme_email is used by cert-manager to register a Let's Encrypt ACME account and issue the wildcard TLS certificate for your domain — registration fails without a real address." >/dev/tty
  local gcp_acme_email
  ask_required gcp_acme_email "ACME email"

  echo "" >/dev/tty
  echo "${bold}Transactional email (invites, notifications sent by the app)${reset}" >/dev/tty
  info "Unrelated to the ACME/TLS setup above — this is a separate, optional choice about which service delivers app emails. By default, Ekai's own licensing portal sends these for you, no setup needed." >/dev/tty
  printf "Provide your own SendGrid or AWS SES credentials for this? [y/N]: " >/dev/tty
  local use_own_email
  read -r use_own_email </dev/tty
  local email_provider="licensing"
  local sendgrid_api_key="" sendgrid_from_email=""
  local ses_aws_region="" aws_access_key_id="" aws_secret_access_key="" aws_ses_from_email=""
  case "$use_own_email" in
    y|Y|yes|Yes)
      printf "  1) SendGrid\n  2) AWS SES\n" >/dev/tty
      printf "Which provider? [1/2]: " >/dev/tty
      local email_choice
      read -r email_choice </dev/tty
      case "$email_choice" in
        1|sendgrid|SendGrid)
          email_provider="sendgrid"
          ask_required sendgrid_api_key "SendGrid API key" -s
          ask_required sendgrid_from_email "SendGrid from-email"
          ;;
        2|ses|SES)
          email_provider="ses"
          printf "AWS SES region [us-east-1]: " >/dev/tty
          read -r ses_aws_region </dev/tty
          ses_aws_region="${ses_aws_region:-us-east-1}"
          ask_required aws_access_key_id "AWS access key ID"
          ask_required aws_secret_access_key "AWS secret access key" -s
          ask_required aws_ses_from_email "SES from-email"
          ;;
        *) die "Invalid choice: $email_choice" ;;
      esac
      ;;
    *) : ;;
  esac

  if [ -d "$GCP_DEPLOY_DIR" ]; then
    warn "${GCP_DEPLOY_DIR} already exists — reusing it as-is (no auto-update). Delete it first for a fresh checkout."
  else
    info "Downloading terraform-google-ekai…"
    local tarball
    tarball=$(mktemp)
    curl -fsSL "$GCP_REPO_TARBALL_URL" -o "$tarball"
    mkdir -p "$GCP_DEPLOY_DIR"
    tar -xzf "$tarball" --strip-components=1 -C "$GCP_DEPLOY_DIR"
    rm -f "$tarball"
    success "Downloaded terraform-google-ekai"
  fi

  local tfvars_dir="${GCP_DEPLOY_DIR}/env"
  local tfvars_file="${tfvars_dir}/${gcp_env}.tfvars"

  if [ -f "$tfvars_file" ]; then
    warn "${tfvars_file} already exists."
    printf "Overwrite it with the values just entered? [Y/n]: " >/dev/tty
    local overwrite
    read -r overwrite </dev/tty
    case "$overwrite" in
      n|N|no|No) info "Keeping existing ${tfvars_file}."; deploy_gcp_run "$gcp_project_id" "$gcp_env" "$gcp_dns_zone"; return ;;
      *) ;;
    esac
  fi

  # Anchored, literal substitutions only — no \b word-boundary (BSD/macOS
  # sed doesn't support it; it silently no-ops instead of erroring, which
  # would leave every "customer" placeholder in place with no warning).
  sed \
    -e "s/^project_id = \"REPLACE_ME\".*/project_id = \"${gcp_project_id}\"/" \
    -e "s/^region     = \"us-east1\"/region     = \"${gcp_region}\"/" \
    -e "s/^env        = \"customer\"/env        = \"${gcp_env}\"/" \
    -e "s/^dns_zone        = \"customer.ekai.ai\".*/dns_zone        = \"${gcp_dns_zone}\"/" \
    -e "s/^acme_email      = \"REPLACE_ME\"/acme_email      = \"${gcp_acme_email}\"/" \
    -e "s/^tls_secret_name = \"customer-wildcard-tls\"/tls_secret_name = \"${gcp_env}-wildcard-tls\"/" \
    "${tfvars_dir}/customer.tfvars" > "$tfvars_file"

  {
    echo ""
    echo "# Added by install.sh — deploy token + licensing portal, same values"
    echo "# written to .env for the local Docker path."
    echo "secret_value_overrides = {"
    echo "  EKAI_DEPLOY_TOKEN         = \"${token}\""
    echo "  EKAI_LICENSING_PORTAL_URL = \"${PORTAL_URL}\""
    echo "  SKIP_CLOUDWATCH           = \"true\""
    echo "  EMAIL_PROVIDER            = \"${email_provider}\""
    case "$email_provider" in
      sendgrid)
        echo "  SENDGRID_API_KEY          = \"${sendgrid_api_key}\""
        echo "  SENDGRID_FROM_EMAIL       = \"${sendgrid_from_email}\""
        ;;
      ses)
        echo "  SES_AWS_REGION            = \"${ses_aws_region}\""
        echo "  AWS_ACCESS_KEY_ID         = \"${aws_access_key_id}\""
        echo "  AWS_SECRET_ACCESS_KEY     = \"${aws_secret_access_key}\""
        echo "  AWS_SES_FROM_EMAIL        = \"${aws_ses_from_email}\""
        ;;
    esac
    echo "}"
  } >> "$tfvars_file"
  success "${tfvars_file} written"

  deploy_gcp_run "$gcp_project_id" "$gcp_env" "$gcp_dns_zone"
}

deploy_gcp_run() {
  local gcp_project_id="$1"
  local gcp_env="$2"
  local gcp_dns_zone="$3"

  echo ""
  info "Ready to deploy to GCP project ${gcp_project_id} (env=${gcp_env})."
  info "This runs terraform-google-ekai/scripts/self-deploy.sh, which will:"
  echo "  - enable required GCP APIs"
  echo "  - create a scoped deployer service account"
  echo "  - run 2 terraform applies (creates real, billable GCP resources)"
  ( cd "$GCP_DEPLOY_DIR" && ./scripts/self-deploy.sh --skip-dns-wait "$gcp_env" )

  # Read back from Terraform state rather than reconstructing the URL
  # ourselves — this is exactly what got deployed (works the same whether
  # this run just applied it or is re-picking-up an existing deployment),
  # and matches self-deploy.sh's own cicd_provider == "none" conditional
  # without duplicating that logic here. A non-empty raw portal_url is also
  # the signal that the cicd apply actually completed (it only exists once
  # that state has been applied).
  #
  # The state backend is a GCS bucket, so reading it needs GCP credentials.
  # self-deploy.sh only exports GOOGLE_APPLICATION_CREDENTIALS for its own
  # process (the deployer SA key it mints) — that doesn't survive past the
  # subshell above, so `terraform output` here would otherwise silently fail
  # (swallowed by `2>/dev/null || true`) using our own gcloud user auth,
  # which was never granted access to that bucket. Reuse the same deployer
  # key file self-deploy.sh already wrote to disk.
  local deployer_key
  deployer_key="$(cd "$(dirname "${GCP_DEPLOY_DIR}/.self-deploy/${gcp_env}-deployer-key.json")" && pwd)/${gcp_env}-deployer-key.json"

  # Captures stderr instead of discarding it (previously `2>/dev/null`) so
  # that when an output comes back empty, the actual Terraform error (wrong
  # backend/state, auth failure, apply that didn't run, ...) is visible below
  # instead of silently falling through to "nothing was deployed this run".
  local tf_err_file
  tf_err_file=$(mktemp)

  local portal_url_raw portal_url_err
  portal_url_raw=$( (cd "${GCP_DEPLOY_DIR}/examples/self-deploy/cicd" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -raw portal_url) 2>"$tf_err_file" || true)
  portal_url_err=$(cat "$tf_err_file")
  local portal_url="${portal_url_raw:-https://portal.${gcp_dns_zone}}"

  local ingress_ip_raw ingress_ip_err
  ingress_ip_raw=$( (cd "${GCP_DEPLOY_DIR}/examples/self-deploy/root" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -raw nginx_ingress_ip) 2>"$tf_err_file" || true)
  ingress_ip_err=$(cat "$tf_err_file")
  local ingress_ip="$ingress_ip_raw"

  rm -f "$tf_err_file"

  local name_servers
  name_servers=$(cd "${GCP_DEPLOY_DIR}/examples/self-deploy/root" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -json name_servers 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)

  # self-deploy.sh exits 0 whether the user actually ran the Terraform apply
  # or answered "N" to its confirmation and skipped it entirely — an empty
  # portal_url_raw AND no ingress_ip means nothing was actually deployed
  # this run (either skipped outright, or it failed before either apply
  # produced an output), so don't claim success.
  if [ -z "$portal_url_raw" ] && [ -z "$ingress_ip" ]; then
    echo ""
    warn "Terraform wasn't applied — nothing was deployed this run."
    if [ -n "$portal_url_err" ]; then
      error "portal_url lookup failed:"
      echo "$portal_url_err" >&2
    fi
    if [ -n "$ingress_ip_err" ]; then
      error "nginx_ingress_ip lookup failed:"
      echo "$ingress_ip_err" >&2
    fi
    info "Re-run install.sh and choose retry for env '${gcp_env}' to continue, answering yes when self-deploy.sh asks to run the Terraform deploy."
    return
  fi

  echo ""
  success "Ekai is running!"
  echo ""
  if [ -n "$ingress_ip" ]; then
    echo "  ${bold}Ekai:${reset}   ${portal_url}   (${ingress_ip})"
    echo ""
    echo "  Note: ${ingress_ip} is the ingress's IP, shown for reference (e.g. to sanity-check DNS once it propagates) —"
    echo "  it isn't verified reachable from outside GCP, since that depends on firewall rules this doesn't configure."
  else
    echo "  ${bold}Ekai:${reset}   ${portal_url}"
  fi

  if [ -n "$name_servers" ]; then
    echo ""
    echo "  ${bold}Before ${gcp_dns_zone} works:${reset} delegate it to these nameservers at your domain registrar"
    echo "  (or parent DNS zone) — add an NS record for ${gcp_dns_zone} pointing at each:"
    echo "$name_servers" | sed 's/^/    /'
    echo "  (shown with GCP's trailing dot — your registrar may not want it in the NS record;"
    echo "  check its own docs/UI to confirm whether to include or drop it.)"
    echo "  DNS propagation can take anywhere from a few minutes to a few hours. Until it's"
    echo "  done, the wildcard TLS cert can't be issued either — the URL above will fail or"
    echo "  show a certificate warning in the meantime."
  fi

  if [ -n "$portal_url_raw" ]; then
    local argocd_url
    argocd_url=$(cd "${GCP_DEPLOY_DIR}/examples/self-deploy/root" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -raw argocd_url 2>/dev/null || true)
    if [ -n "$argocd_url" ]; then
      echo ""
      if [ -n "$ingress_ip" ]; then
        echo "  ${bold}ArgoCD:${reset} ${argocd_url}   (${ingress_ip})"
      else
        echo "  ${bold}ArgoCD:${reset} ${argocd_url}"
      fi
      echo "  (user: admin, password:"
      echo "    cd ${GCP_DEPLOY_DIR}/examples/self-deploy/root"
      echo "    GOOGLE_APPLICATION_CREDENTIALS=${deployer_key} terraform output -raw argocd_admin_password_plaintext)"
    fi
  fi
  echo ""
}

# ── AWS deployment ────────────────────────────────────────────────────────────
# Checks every tool terraform-aws-ekai's self-deploy.sh needs (terraform,
# kubectl, jq, dig — no gcloud/gke-gcloud-auth-plugin equivalent: EKS auth
# goes through the aws CLI directly), offers to auto-install whatever's
# missing (install_cmd_for already has entries for all of these, shared with
# the GCP path), and reports anything still missing — all before asking any
# of deploy_aws's region/env/dns_zone questions.
check_aws_tools() {
  reset_missing_tools
  need terraform "Install it: see https://developer.hashicorp.com/terraform/install (on Windows, install it inside WSL following the Linux instructions)"
  # self-deploy.sh's cicd apply needs kubectl to auth against the EKS
  # cluster it just created, same reason as the GCP path.
  need kubectl "Install it: see https://kubernetes.io/docs/tasks/tools/ (on Windows, install it inside WSL following the Linux instructions)"
  # self-deploy.sh itself needs jq to parse aws CLI JSON output.
  need jq "Install it with: brew install jq (macOS) or sudo apt install jq / sudo yum install jq (Linux) — on Windows, install it inside WSL following the Linux instructions."
  # self-deploy.sh polls DNS (via dig) to confirm the domain's name servers
  # have propagated before continuing.
  need dig "Install it with: brew install bind (macOS) or sudo apt install dnsutils / sudo yum install bind-utils (Linux) — on Windows, install it inside WSL following the Linux instructions."

  offer_auto_install_missing_tools
}

check_aws_prereqs() {
  check_aws_tools
  [ -z "$_missing_tools" ]
}

# Confirms the identity `aws configure` (or SSO, or a named profile) has
# active right now can actually bootstrap a deployment -- self-deploy.sh
# creates one IAM user + two IAM policies under THIS identity before
# Terraform ever runs (see terraform-aws-ekai/PERMISSIONS.md — "the
# bootstrapping identity"). Uses iam:SimulatePrincipalPolicy against the
# caller's own ARN rather than checking attached role names — that only sees
# direct bindings, this reports the real effective permission regardless of
# whether it came from a direct policy, a group, or an org-level grant. Same
# tool (and same reasoning) used to actually diagnose this project's own
# real permission gaps earlier, not a new approach invented just for this
# check.
check_aws_permissions() {
  # || true throughout this function: under set -e, a failing command
  # inside a bare var=$(...) assignment kills the script right there --
  # every die/warn below would silently never run otherwise (verified:
  # even the `if [ $? -ne 0 ]` pattern further down doesn't save you, since
  # set -e fires on the assignment itself, before that check is ever
  # reached).
  local caller_arn
  caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
  [ -n "$caller_arn" ] || die "Could not determine the current AWS identity. Run: aws configure"

  # simulate-principal-policy rejects an assumed-role ARN outright (SSO
  # logins and anything else that goes through AssumeRole all show up as
  # one) -- it only takes a real user/group/role ARN. Can't just prepend
  # role/<name> to rebuild it either: an assumed-role ARN never carries the
  # role's path, and SSO permission-set roles live under
  # /aws-reserved/sso.amazonaws.com/<region>/ -- guessing "no path" there
  # builds an ARN that doesn't exist. Look the role up by name instead (AWS
  # resolves role names uniquely account-wide, path or not, so this doesn't
  # need to know or guess the path) and use whatever ARN it actually hands
  # back. keep caller_arn as-is for the messages below either way, since
  # that's the identity the person actually knows.
  local policy_arn="$caller_arn"
  if [[ "$caller_arn" == *:assumed-role/* ]]; then
    local role_name real_role_arn
    role_name=$(echo "$caller_arn" | cut -d/ -f2)
    real_role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text 2>/dev/null || true)
    if [ -n "$real_role_arn" ] && [ "$real_role_arn" != "None" ]; then
      policy_arn="$real_role_arn"
    else
      warn "Could not look up the real ARN for role '${role_name}' (needs iam:GetRole) -- skipping the permission pre-check. self-deploy.sh will still fail clearly later if something's actually missing."
      success "Continuing without a permission pre-check for ${caller_arn}"
      return 0
    fi
  fi

  # `cmd && rc=$? || rc=$?` instead of a bare assignment + `if [ $? -ne 0 ]`
  # afterward -- that pattern looks like it handles failure but doesn't
  # under set -e: the assignment's own failure exits the script before the
  # separate `if` line is ever reached. This form never lets the failure
  # propagate as the statement's own exit status, so set -e stays quiet and
  # $rc reliably holds the real code either way.
  local response rc
  response=$(aws iam simulate-principal-policy \
    --policy-source-arn "$policy_arn" \
    --action-names \
      iam:GetUser iam:CreateUser iam:DeleteUser \
      iam:AttachUserPolicy iam:DetachUserPolicy \
      iam:ListAccessKeys iam:CreateAccessKey iam:DeleteAccessKey iam:UpdateAccessKey \
      iam:GetPolicy iam:GetPolicyVersion iam:ListPolicyVersions \
      iam:CreatePolicy iam:CreatePolicyVersion iam:DeletePolicyVersion \
    --output json 2>&1) && rc=$? || rc=$?
  if [ "$rc" -ne 0 ]; then
    error "Could not run the IAM permission check for ${caller_arn}:"
    echo "$response" >&2
    die "Check AWS credentials are valid (aws sts get-caller-identity) and re-run."
  fi

  local missing
  missing=$(echo "$response" | jq -r '.EvaluationResults[] | select(.EvalDecision != "allowed") | .EvalActionName')

  if [ -n "$missing" ]; then
    error "${caller_arn} is missing required IAM permissions to bootstrap a deployment:"
    echo "$missing" | sed 's/^/  /' >&2
    die "See https://github.com/ekai-ai/terraform-aws-ekai/blob/main/PERMISSIONS.md (\"bootstrapping identity\") for the exact policy to grant, then re-run."
  fi
  success "AWS permissions verified for ${caller_arn}"
}

deploy_aws() {
  local token="$1"

  echo "" >/dev/tty
  info "Checking AWS credentials/permissions…" >/dev/tty
  check_aws_permissions

  printf "AWS region [us-east-1]: " >/dev/tty
  local aws_region
  read -r aws_region </dev/tty
  aws_region="${aws_region:-us-east-1}"

  echo "" >/dev/tty
  warn "The environment name becomes part of every AWS resource this creates (the EKS cluster, the IAM deployer user, the S3 state bucket, ...) — it must be unique per deployment." >/dev/tty
  local aws_env=""
  while [ -z "$aws_env" ]; do
    printf "Environment name: " >/dev/tty
    read -r aws_env </dev/tty
    if [ -z "$aws_env" ]; then
      printf "Environment name is required: " >/dev/tty
    elif [ "$aws_env" = "customer" ]; then
      warn "\"customer\" is reserved (it's the template file itself) — pick a different environment name." >/dev/tty
      aws_env=""
    elif [ ${#aws_env} -gt 20 ]; then
      printf "Environment name must be 20 characters or fewer (got %d) — the S3 state bucket name is \"ekai-terraform-state-<env>-<region>\", capped at 63 chars total: " "${#aws_env}" >/dev/tty
      aws_env=""
    fi
  done

  echo "" >/dev/tty
  info "dns_zone is the domain (or subdomain) you control DNS for — Ekai creates a Route53 zone under it, which you'll delegate to AWS's nameservers at your registrar afterward." >/dev/tty
  local aws_dns_zone
  ask_required aws_dns_zone "DNS zone (e.g. example.com)"

  echo "" >/dev/tty
  echo "${bold}Transactional email (invites, notifications sent by the app)${reset}" >/dev/tty
  info "This is a separate, optional choice about which service delivers app emails — unrelated to which cloud hosts the deployment. By default, Ekai's own licensing portal sends these for you, no setup needed." >/dev/tty
  printf "Provide your own SendGrid or AWS SES credentials for this? [y/N]: " >/dev/tty
  local use_own_email
  read -r use_own_email </dev/tty
  local email_provider="licensing"
  local sendgrid_api_key="" sendgrid_from_email=""
  local ses_aws_region="" aws_ses_access_key_id="" aws_ses_secret_access_key="" aws_ses_from_email=""
  case "$use_own_email" in
    y|Y|yes|Yes)
      printf "  1) SendGrid\n  2) AWS SES\n" >/dev/tty
      printf "Which provider? [1/2]: " >/dev/tty
      local email_choice
      read -r email_choice </dev/tty
      case "$email_choice" in
        1|sendgrid|SendGrid)
          email_provider="sendgrid"
          ask_required sendgrid_api_key "SendGrid API key" -s
          ask_required sendgrid_from_email "SendGrid from-email"
          ;;
        2|ses|SES)
          email_provider="ses"
          printf "AWS SES region [us-east-1]: " >/dev/tty
          read -r ses_aws_region </dev/tty
          ses_aws_region="${ses_aws_region:-us-east-1}"
          ask_required aws_ses_access_key_id "AWS access key ID"
          ask_required aws_ses_secret_access_key "AWS secret access key" -s
          ask_required aws_ses_from_email "SES from-email"
          ;;
        *) die "Invalid choice: $email_choice" ;;
      esac
      ;;
    *) : ;;
  esac

  if [ -d "$AWS_DEPLOY_DIR" ]; then
    warn "${AWS_DEPLOY_DIR} already exists — reusing it as-is (no auto-update). Delete it first for a fresh checkout."
  else
    info "Downloading terraform-aws-ekai…"
    local tarball
    tarball=$(mktemp)
    curl -fsSL "$AWS_REPO_TARBALL_URL" -o "$tarball"
    mkdir -p "$AWS_DEPLOY_DIR"
    tar -xzf "$tarball" --strip-components=1 -C "$AWS_DEPLOY_DIR"
    rm -f "$tarball"
    success "Downloaded terraform-aws-ekai"
  fi

  local tfvars_dir="${AWS_DEPLOY_DIR}/env"
  local tfvars_file="${tfvars_dir}/${aws_env}.tfvars"

  if [ -f "$tfvars_file" ]; then
    warn "${tfvars_file} already exists."
    printf "Overwrite it with the values just entered? [Y/n]: " >/dev/tty
    local overwrite
    read -r overwrite </dev/tty
    case "$overwrite" in
      n|N|no|No) info "Keeping existing ${tfvars_file}."; deploy_aws_run "$aws_env" "$aws_dns_zone"; return ;;
      *) ;;
    esac
  fi

  # Anchored, literal substitutions only — no \b word-boundary (BSD/macOS
  # sed doesn't support it; it silently no-ops instead of erroring, which
  # would leave every "customer" placeholder in place with no warning).
  sed \
    -e "s/^region[[:space:]]*=[[:space:]]*\"us-east-1\"/region = \"${aws_region}\"/" \
    -e "s/^env[[:space:]]*=[[:space:]]*\"customer\"/env = \"${aws_env}\"/" \
    -e "s/^dns_zone[[:space:]]*=[[:space:]]*\"customer.ekai.ai\".*/dns_zone        = \"${aws_dns_zone}\"/" \
    "${tfvars_dir}/customer.tfvars" > "$tfvars_file"

  {
    echo ""
    echo "# Added by install.sh — deploy token + licensing portal, same values"
    echo "# written to .env for the local Docker path."
    echo "secret_value_overrides = {"
    echo "  EKAI_DEPLOY_TOKEN         = \"${token}\""
    echo "  EKAI_LICENSING_PORTAL_URL = \"${PORTAL_URL}\""
    echo "  EMAIL_PROVIDER            = \"${email_provider}\""
    case "$email_provider" in
      sendgrid)
        echo "  SENDGRID_API_KEY          = \"${sendgrid_api_key}\""
        echo "  SENDGRID_FROM_EMAIL       = \"${sendgrid_from_email}\""
        ;;
      ses)
        echo "  SES_AWS_REGION            = \"${ses_aws_region}\""
        echo "  AWS_ACCESS_KEY_ID         = \"${aws_ses_access_key_id}\""
        echo "  AWS_SECRET_ACCESS_KEY     = \"${aws_ses_secret_access_key}\""
        echo "  AWS_SES_FROM_EMAIL        = \"${aws_ses_from_email}\""
        ;;
    esac
    echo "}"
  } >> "$tfvars_file"
  success "${tfvars_file} written"

  deploy_aws_run "$aws_env" "$aws_dns_zone"
}

deploy_aws_run() {
  local aws_env="$1"
  local aws_dns_zone="$2"

  echo ""
  info "Ready to deploy to AWS (env=${aws_env})."
  info "This runs terraform-aws-ekai/scripts/self-deploy.sh, which will:"
  echo "  - create a scoped IAM deployer user (see PERMISSIONS.md)"
  echo "  - run 2 terraform applies (creates real, billable AWS resources)"
  # No --skip-dns-wait here -- self-deploy.sh runs its normal, full
  # interactive flow (waits for Enter, polls for DNS propagation, then both
  # applies) in this one call, exactly like a direct run would. Only
  # install.sh's own invocation changed; the flag itself is untouched in
  # self-deploy.sh for anyone who still wants it directly.
  #
  # >/dev/tty: self-deploy.sh has no tty redirects of its own (it's meant to
  # also be run directly, where plain stdout is correct). Nested this deep
  # under the curl|bash re-exec, plain stdout doesn't reliably reach the
  # screen even though fd 1 nominally still points at the terminal -- same
  # class of issue the re-exec above exists for. Forcing it onto /dev/tty
  # here, at the call site, fixes it for this invocation without changing
  # self-deploy.sh's own behavior for anyone running it directly.
  ( cd "$AWS_DEPLOY_DIR" && ./scripts/self-deploy.sh "$aws_env" ) >/dev/tty

  # Mirrors deploy_gcp_run's own portal_url check exactly. A non-empty
  # portal_url is the signal the cicd apply actually completed; empty means
  # nothing was deployed this run (declined the confirmation, or a failure
  # before cicd ever ran).
  local tf_err_file
  tf_err_file=$(mktemp)

  local portal_url_raw portal_url_err
  portal_url_raw=$( (cd "${AWS_DEPLOY_DIR}/examples/self-deploy/cicd" && terraform output -raw portal_url) 2>"$tf_err_file" || true)
  portal_url_err=$(cat "$tf_err_file")
  rm -f "$tf_err_file"

  local name_servers
  name_servers=$(cd "${AWS_DEPLOY_DIR}/examples/self-deploy/root" && terraform output -json route53_name_servers 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)

  if [ -z "$portal_url_raw" ]; then
    echo ""
    warn "Terraform wasn't fully applied — nothing was deployed this run."
    if [ -n "$portal_url_err" ] && ! echo "$portal_url_err" | grep -q "Output \"portal_url\" not found\|No state file\|Backend initialization required"; then
      error "portal_url lookup failed:"
      echo "$portal_url_err" >&2
    fi
    if [ -n "$name_servers" ]; then
      echo ""
      echo "  ${bold}Before ${aws_dns_zone} works:${reset} delegate it to these nameservers at your domain"
      echo "  registrar (or parent DNS zone) — add an NS record for ${aws_dns_zone} pointing at each:"
      echo "$name_servers" | sed 's/^/    /'
      echo "  DNS propagation can take anywhere from a few minutes to a few hours."
    fi
    info "Re-run install.sh and choose retry for env '${aws_env}' to continue, answering yes when self-deploy.sh asks to run the Terraform deploy."
    return
  fi

  echo ""
  success "Ekai is running!"
  echo ""
  echo "  ${bold}Ekai:${reset}   ${portal_url_raw}"

  local argocd_url
  argocd_url=$(cd "${AWS_DEPLOY_DIR}/examples/self-deploy/root" && terraform output -raw argocd_url 2>/dev/null || true)
  if [ -n "$argocd_url" ]; then
    echo ""
    echo "  ${bold}ArgoCD:${reset} ${argocd_url}"
    echo "  (user: admin, password:"
    echo "    cd ${AWS_DEPLOY_DIR}/examples/self-deploy/root"
    echo "    terraform output -raw argocd_admin_password_plaintext)"
  fi
  echo ""
}

deploy_cloud() {
  local token="$1"
  local provider="$2"

  need helm "Install it from https://helm.sh/docs/intro/install/."

  # Write token to env file regardless
  local tmp
  tmp=$(mktemp)
  if [ -f "$ENV_FILE" ]; then
    grep -v "^EKAI_DEPLOY_TOKEN=" "$ENV_FILE" > "$tmp" || true
  fi
  echo "EKAI_DEPLOY_TOKEN=${token}" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  success "${ENV_FILE} updated with EKAI_DEPLOY_TOKEN"

  echo ""
  warn "Cloud deployment via Helm is not yet fully automated."
  echo ""
  echo "  ${bold}Your deploy token has been saved to ${ENV_FILE}.${reset}"
  echo ""
  echo "  When your Helm chart is ready, run:"
  echo ""
  echo "  ${bold}helm upgrade --install ekai <CHART_REPO>/ekai \\"
  echo "    --set ekai.deployToken=${token} \\"
  echo "    --set ekai.licensingUrl=https://app.ekai.ai${reset}"
  echo ""
  echo "  Contact hello@ekai.ai for the Helm chart details."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "${bold}${cyan}Ekai deployer${reset}"
  echo "────────────────────"
  echo ""

  # Check for leftover artifacts from a previous GCP deploy run before asking
  # anything else — resuming skips straight past the docker/cloud choice and
  # every prompt in deploy_gcp, since all of that is already answered in the
  # env's existing tfvars. Deliberately doesn't try to guess whether that
  # prior run succeeded, failed, or is still stuck — the user already saw its
  # logs and knows better than any local-file heuristic could.
  local partial_env
  partial_env=$(detect_partial_deploy "$GCP_DEPLOY_DIR" "-deployer-key.json")
  if [ -n "$partial_env" ]; then
    echo "" >/dev/tty
    warn "Found previous run artifacts for GCP env '${partial_env}'." >/dev/tty
    printf "Retry that deploy instead of starting a new one? [y/N] " >/dev/tty
    local resume_choice
    read -r resume_choice </dev/tty
    case "$resume_choice" in
      y|Y|yes|Yes)
        check_gcp_requirements
        local tfvars_dir="${GCP_DEPLOY_DIR}/env"
        local tfvars_file="${tfvars_dir}/${partial_env}.tfvars"
        local resume_project_id
        local resume_dns_zone
        # || true: pipefail means a no-match grep fails the whole pipeline
        # even though head/sed after it succeed -- same silent-death risk
        # under set -e as every other var=$(...) in this file.
        resume_project_id=$(grep -E '^project_id[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' || true)
        resume_dns_zone=$(grep -E '^dns_zone[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' || true)
        [ -n "$resume_project_id" ] || die "Could not read project_id back from ${tfvars_file} — fix or delete it and start a new deployment."
        deploy_gcp_run "$resume_project_id" "$partial_env" "$resume_dns_zone"
        return
        ;;
      *) info "Starting a new deployment." ;;
    esac
  fi

  # Same check for a previous AWS run, same detect_partial_deploy helper —
  # this one's still handled as its own separate block rather than a loop
  # over providers, since everything past the detect call (resume prompt,
  # which tfvars fields to read back, which *_run function to call) is
  # still provider-specific.
  local partial_aws_env
  partial_aws_env=$(detect_partial_deploy "$AWS_DEPLOY_DIR" "-generated-secrets.txt")
  if [ -n "$partial_aws_env" ]; then
    echo "" >/dev/tty
    warn "Found previous run artifacts for AWS env '${partial_aws_env}'." >/dev/tty
    printf "Retry that deploy instead of starting a new one? [y/N] " >/dev/tty
    local aws_resume_choice
    read -r aws_resume_choice </dev/tty
    case "$aws_resume_choice" in
      y|Y|yes|Yes)
        if check_aws_prereqs; then
          local tfvars_dir="${AWS_DEPLOY_DIR}/env"
          local tfvars_file="${tfvars_dir}/${partial_aws_env}.tfvars"
          local resume_dns_zone
          # || true: pipefail means a no-match grep fails the whole pipeline
          # even though head/sed after it succeed -- same silent-death risk
          # under set -e as every other var=$(...) in this file.
          resume_dns_zone=$(grep -E '^dns_zone[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' || true)
          deploy_aws_run "$partial_aws_env" "$resume_dns_zone"
          return
        else
          echo ""
          die "One or more AWS prerequisites are missing. Fix the issues above and re-run."
        fi
        ;;
      *) info "Starting a new deployment." ;;
    esac
  fi

  # Deployment type
  local deploy_type
  deploy_type=$(ask_deployment_type)

  local token_output token user_email
  if [ "$deploy_type" = "local" ]; then
    local is_rerun=0
    if local_install_exists; then
      warn "A local Ekai deployment already exists on this machine."
      if ask_yes_no "Redeploy it?" n; then
        is_rerun=1
      else
        # No redeploy, no token needed: just offer the sample data.
        maybe_load_northwind ask
        print_northwind_info
        return
      fi
    fi

    # Get deploy token + user email via browser login
    token_output=$(get_token_via_browser)
    token=$(printf '%s' "$token_output" | head -1)
    user_email=$(printf '%s' "$token_output" | tail -1)
    success "Deploy token received"
    deploy_local "$token" "$user_email" "$is_rerun"
  else
    token_output=$(get_token_via_browser)
    token=$(printf '%s' "$token_output" | head -1)
    user_email=$(printf '%s' "$token_output" | tail -1)
    success "Deploy token received"

    local provider
    provider=$(ask_cloud_provider)

    if [ "$provider" = "other" ]; then
      deploy_cloud "$token" "other"
    elif [ "$provider" = "gcp" ]; then
      # Run every independent GCP prereq (gcloud CLI/auth, terraform,
      # kubectl, gke-gcloud-auth-plugin, jq, dig) in one batch so a single
      # missing tool doesn't stop the rest from being checked and reported.
      if check_gcp_prereqs; then
        deploy_gcp "$token"
      else
        echo ""
        die "One or more GCP prerequisites are missing. Fix the issues above and re-run."
      fi
    elif [ "$provider" = "aws" ]; then
      if check_cloud_cli "$provider" && check_aws_prereqs; then
        deploy_aws "$token"
      else
        echo ""
        die "One or more AWS prerequisites are missing. Fix the issues above and re-run."
      fi
    else
      if check_cloud_cli "$provider"; then
        deploy_cloud "$token" "$provider"
      else
        echo ""
        die "CLI check failed. Fix your CLI auth and re-run the installer."
      fi
    fi
  fi
}

main "$@"
