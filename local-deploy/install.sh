#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# ekai trial installer
# Usage: curl -fsSL https://raw.githubusercontent.com/ekai-ai/ekai-deployer/refs/heads/main/install.sh | sh
# ──────────────────────────────────────────────────────────────────────────────

PORTAL_URL="https://dev.licensing.ekai.ai"  # production default — uncomment for prod
CALLBACK_PORT="${EKAI_CALLBACK_PORT:-9999}"
BASE_URL="https://raw.githubusercontent.com/ekai-ai/ekai-deployer/refs/heads/dev"
COMPOSE_URL="${BASE_URL}/local-deploy/docker-compose.yml"
ENV_EXAMPLE_URL="${BASE_URL}/local-deploy/.env.example"
ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"


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
need() {
  command -v "$1" &>/dev/null || die "Required tool not found: $1. Please install it and re-run."
}

need curl

# ── Step 1: get deploy token via browser login ─────────────────────────────────
get_token_via_browser() {
  local callback_url="http://localhost:${CALLBACK_PORT}/token"
  local portal_page="${PORTAL_URL}/install?callback=${callback_url}"

  # Spin up a Python HTTP server that stays alive across multiple connections.
  # It writes the received token to a temp file and exits once it has one.
  local token_file
  token_file=$(mktemp)

  python3 - "$CALLBACK_PORT" "$token_file" <<'PYEOF' &
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

  if command -v open &>/dev/null; then
    open "$portal_page"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$portal_page"
  else
    warn "Could not open browser automatically. Please open the URL above manually." >/dev/tty
  fi

  info "Waiting for token from portal (listening on port ${CALLBACK_PORT})…" >/dev/tty
  echo "  (If the browser doesn't open, visit the URL above, then copy your" >/dev/tty
  echo "   EKAI_DEPLOY_TOKEN from the portal and paste it when prompted.)" >/dev/tty
  echo "" >/dev/tty

  # Give it 3 minutes to receive the token
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
    warn "Did not receive token automatically." >/dev/tty
    printf "Paste your exchange token from the portal here: " >/dev/tty
    read -r exchange_token </dev/tty
  fi

  [ -n "$exchange_token" ] || die "No token provided. Cannot continue."

  # Redeem the exchange token for the deploy token + email
  info "Redeeming token…" >/dev/tty
  local redeem_response
  redeem_response=$(curl -s -X POST "${PORTAL_URL}/api/auth/exchange-token/redeem" \
    -H "Content-Type: application/json" \
    -d "{\"exchangeToken\":\"${exchange_token}\"}")

  local deploy_token
  local user_email
  deploy_token=$(printf '%s' "$redeem_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['apiKey'])" 2>/dev/null || true)
  user_email=$(printf '%s' "$redeem_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null || true)

  if [ -z "$deploy_token" ]; then
    die "Failed to redeem token. Please re-run the installer and try again."
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
      warn "Unknown architecture: $arch — defaulting to linux/amd64"
      echo "linux/amd64"
      ;;
  esac
}

check_local_requirements() {
  need docker

  # Docker running?
  docker info &>/dev/null || die "Docker is not running. Please start Docker Desktop and re-run."
  success "Docker is running"

  # Available disk space >= 8 GB (in the Docker VM / current mount)
  local free_kb
  free_kb=$(df -Pk . | awk 'NR==2 {print $4}')
  local free_gb=$(( free_kb / 1024 / 1024 ))
  if [ "$free_gb" -lt 3 ]; then
    die "Not enough disk space: ${free_gb} GB free, 3 GB required. Free up space and re-run."
  fi
  success "Disk space: ${free_gb} GB free"

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
}

deploy_local() {
  local token="$1"
  local user_email="${2:-}"

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

  # Inject / update EKAI_DEPLOY_TOKEN and DOCKER_PLATFORM
  local tmp
  tmp=$(mktemp)
  grep -v -E "^EKAI_DEPLOY_TOKEN=|^DOCKER_PLATFORM=" "$ENV_FILE" > "$tmp" || true
  {
    echo "EKAI_DEPLOY_TOKEN=${token}"
    echo "DOCKER_PLATFORM=${platform}"
  } >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  success "${ENV_FILE} updated (EKAI_DEPLOY_TOKEN + DOCKER_PLATFORM set)"

  # Bring up the stack
  echo ""
  info "Starting ekai with Docker Compose…"
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile app up -d

  # Seed the user account if we have an email
  if [ -n "$user_email" ]; then
    info "Waiting for database migrations to complete…"
    until docker exec ekai-postgres psql -U ekai -d ekaibackend -c '\dt "Users"' 2>/dev/null | grep -q Users; do
      sleep 3
    done
    success "Database is ready"

    info "Seeding user account (${user_email})…"
    docker exec -i ekai-postgres psql -U ekai -d ekaibackend -v ON_ERROR_STOP=1 -q <<SQL
INSERT INTO "Users" (id, email, name, status, "roleId", "createdAt")
VALUES (gen_random_uuid(), '${user_email}', '${user_email}', 'active', 4, now())
ON CONFLICT (email) DO NOTHING;

INSERT INTO "UserCredentials" ("userId", password, "createdAt", "updatedAt")
SELECT id, NULL, now(), now() FROM "Users" WHERE email = '${user_email}'
ON CONFLICT ("userId") DO NOTHING;

INSERT INTO "Tenants" (name, "subscriptionId", "createdById")
SELECT 'My Tenant', s.id, u.id
FROM "Subscription" s, "Users" u
WHERE s.name = 'Trial' AND u.email = '${user_email}'
  AND NOT EXISTS (SELECT 1 FROM "Tenants" LIMIT 1);

INSERT INTO "TenantUsers" ("tenantId", "userId")
SELECT t.id, u.id
FROM "Tenants" t, "Users" u
WHERE u.email = '${user_email}'
ORDER BY t.id
LIMIT 1
ON CONFLICT DO NOTHING;
SQL
    local seeded_email
    seeded_email=$(docker exec ekai-postgres psql -U ekai -d ekaibackend -tAq \
      -c "SELECT email FROM \"Users\" WHERE email = '${user_email}' LIMIT 1;" 2>/dev/null || true)
    if [ "$seeded_email" = "$user_email" ]; then
      success "Account ready for ${user_email}"
    else
      die "User seeding failed for ${user_email} — account was not created in the database."
    fi
  fi

  echo ""
  success "ekai is running!"
  echo ""
  echo "  ${bold}Platform UI:${reset}   http://localhost:80"
  echo "  ${bold}AI Core API:${reset}   http://localhost:9002"
  echo ""
  echo "To stop:   ${bold}docker compose -f ${COMPOSE_FILE} --profile app down${reset}"
  echo "To update: ${bold}docker compose -f ${COMPOSE_FILE} --profile app pull && docker compose -f ${COMPOSE_FILE} --profile app up -d${reset}"
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
        warn "gcloud CLI not found. Install it from https://cloud.google.com/sdk/docs/install"
        return 1
      fi
      ;;
  esac
  return 0
}

deploy_cloud() {
  local token="$1"
  local provider="$2"

  need helm

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
  echo "${bold}${cyan}ekai trial installer${reset}"
  echo "────────────────────"
  echo ""

  # Get deploy token + user email via browser login
  local token_output
  token_output=$(get_token_via_browser)
  local token
  local user_email
  token=$(printf '%s' "$token_output" | head -1)
  user_email=$(printf '%s' "$token_output" | tail -1)
  success "Deploy token received"

  # Deployment type
  local deploy_type
  deploy_type=$(ask_deployment_type)

  if [ "$deploy_type" = "local" ]; then
    deploy_local "$token" "$user_email"
  else
    local provider
    provider=$(ask_cloud_provider)

    if [ "$provider" = "other" ]; then
      deploy_cloud "$token" "other"
    else
      if check_cloud_cli "$provider"; then
        deploy_cloud "$token" "$provider"
      else
        echo ""
        warn "CLI check failed. You can still proceed manually."
        printf "Continue anyway? [y/N]: " >/dev/tty
        read -r cont </dev/tty
        case "$cont" in
          y|Y|yes|Yes) deploy_cloud "$token" "$provider" ;;
          *) info "Exiting. Fix your CLI auth and re-run the installer."; exit 0 ;;
        esac
      fi
    fi
  fi
}

main "$@"
