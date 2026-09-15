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
GCP_REPO_TARBALL_URL="https://github.com/ekai-ai/terraform-google-ekai/archive/refs/heads/main.tar.gz"
GCP_DEPLOY_DIR="terraform-google-ekai" # relative to cwd, downloaded below


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

  # Inject / update EKAI_DEPLOY_TOKEN, DOCKER_PLATFORM, and SANDBOX_REQUIRED
  local tmp
  tmp=$(mktemp)
  grep -v -E "^EKAI_DEPLOY_TOKEN=|^DOCKER_PLATFORM=|^SANDBOX_REQUIRED=" "$ENV_FILE" > "$tmp" || true
  {
    echo "EKAI_DEPLOY_TOKEN=${token}"
    echo "DOCKER_PLATFORM=${platform}"
    echo "SANDBOX_REQUIRED=${sandbox_required}"
  } >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  success "${ENV_FILE} updated (EKAI_DEPLOY_TOKEN + DOCKER_PLATFORM + SANDBOX_REQUIRED set)"

  # Pull images one at a time. --parallel is not available on all Compose
  # versions (e.g. 2.3.3), so pull each service individually instead — this
  # works everywhere and avoids bursting the registry's rate limit.
  echo ""
  info "Pulling images…"
  local svc
  for svc in $(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile app config --services); do
    info "Pulling ${svc}…"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile app pull "$svc"
  done

  # Bring up the stack
  echo ""
  info "Starting ekai with Docker Compose…"
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile app up -d --force-recreate

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
  success "Ekai is running!"
  echo ""
  echo "  ${bold}Ekai:${reset}   http://localhost:80"
  echo ""
  echo "To stop:   ${bold}docker compose -f ${COMPOSE_FILE} --profile app down${reset}"
  echo "To update: ${bold}for s in \$(docker compose -f ${COMPOSE_FILE} --profile app config --services); do docker compose -f ${COMPOSE_FILE} --profile app pull \"\$s\"; done && docker compose -f ${COMPOSE_FILE} --profile app up -d${reset}"
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

check_gcp_requirements() {
  need terraform
  # self-deploy.sh's cicd apply needs `kubectl` to auth against the GKE
  # cluster it just created — modern GKE requires this plugin for that
  # rather than gcloud's older built-in auth, and kubectl fails with a
  # cryptic error mid-deploy without it.
  command -v gke-gcloud-auth-plugin &>/dev/null || die "Required tool not found: gke-gcloud-auth-plugin. Install it with: gcloud components install gke-gcloud-auth-plugin"
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
  # -level grant. No jq dependency (that's self-deploy.sh's requirement to
  # check, once it's actually running) — the response is simple enough to
  # parse with grep.
  local access_token
  access_token=$(gcloud auth print-access-token 2>/dev/null || true)
  [ -n "$access_token" ] || die "No active gcloud access token. Run: gcloud auth login"

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
    ]}')

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

# Looks for local signs that a GCP deploy was previously started for some env
# (a generated tfvars + deployer key or backend config) — this catches a
# self-deploy.sh run that errored, timed out, or was interrupted partway, as
# well as a run that finished cleanly. Prints the candidate env name on
# stdout if found, empty otherwise. Deliberately doesn't try to tell those
# cases apart (e.g. by reading Terraform output) — the user already saw that
# run's logs and knows whether it succeeded better than any local-file/state
# heuristic could; this only surfaces that artifacts exist so they can choose
# to retry or start fresh.
detect_gcp_partial_deploy() {
  [ -d "$GCP_DEPLOY_DIR" ] || return 0
  local tfvars_dir="${GCP_DEPLOY_DIR}/env"
  [ -d "$tfvars_dir" ] || return 0

  # Most-recently-modified non-template tfvars file is our one candidate —
  # good enough for "did a previous run leave something behind", not meant
  # to handle multiple concurrent in-progress envs.
  local candidate
  candidate=$(ls -t "${tfvars_dir}"/*.tfvars 2>/dev/null | grep -v '/customer\.tfvars$' | head -1 || true)
  [ -n "$candidate" ] || return 0

  local env_name
  env_name=$(basename "$candidate" .tfvars)

  local deployer_key="${GCP_DEPLOY_DIR}/.self-deploy/${env_name}-deployer-key.json"
  local backend_file="${tfvars_dir}/backend-${env_name}.tfbackend"

  # Deployer key or backend config existing means self-deploy.sh got at
  # least as far as Step 2/3 — real signal something was attempted, not
  # just a tfvars file the user hand-edited and never ran. Note the
  # deployer key is meant to be deleted after copying it somewhere safe
  # (self-deploy.sh says so at the end), so its absence alone doesn't mean
  # anything — the backend file check covers that case.
  [ -f "$deployer_key" ] || [ -f "$backend_file" ] || return 0

  echo "$env_name"
}

deploy_gcp() {
  local token="$1"

  echo "" >/dev/tty
  printf "GCP project ID: " >/dev/tty
  local gcp_project_id=""
  while [ -z "$gcp_project_id" ]; do
    read -r gcp_project_id </dev/tty
    [ -n "$gcp_project_id" ] || printf "GCP project ID (required): " >/dev/tty
  done

  check_gcp_permissions "$gcp_project_id"

  printf "GCP region [us-east1]: " >/dev/tty
  local gcp_region
  read -r gcp_region </dev/tty
  gcp_region="${gcp_region:-us-east1}"

  echo "" >/dev/tty
  warn "The environment name becomes part of every GCP resource this creates — it must be unique per deployment, and 13 characters or fewer (GCP service account IDs cap the room this leaves)." >/dev/tty
  printf "Environment name [customer]: " >/dev/tty
  local gcp_env
  while :; do
    read -r gcp_env </dev/tty
    gcp_env="${gcp_env:-customer}"
    if [ "${#gcp_env}" -gt 13 ]; then
      printf "Environment name must be 13 characters or fewer (got %d): " "${#gcp_env}" >/dev/tty
    else
      break
    fi
  done

  echo "" >/dev/tty
  info "dns_zone is the domain (or subdomain) you control DNS for — Ekai creates a Cloud DNS zone under it, which you'll delegate to Google's nameservers at your registrar afterward." >/dev/tty
  local gcp_dns_zone=""
  printf "DNS zone (e.g. client1.ekai.ai): " >/dev/tty
  while [ -z "$gcp_dns_zone" ]; do
    read -r gcp_dns_zone </dev/tty
    [ -n "$gcp_dns_zone" ] || printf "DNS zone (required): " >/dev/tty
  done

  echo "" >/dev/tty
  info "acme_email is used by cert-manager to register a Let's Encrypt ACME account and issue the wildcard TLS certificate for your domain — registration fails without a real address." >/dev/tty
  local gcp_acme_email=""
  printf "ACME email: " >/dev/tty
  while [ -z "$gcp_acme_email" ]; do
    read -r gcp_acme_email </dev/tty
    [ -n "$gcp_acme_email" ] || printf "ACME email (required): " >/dev/tty
  done

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
          printf "SendGrid API key: " >/dev/tty
          while [ -z "$sendgrid_api_key" ]; do
            read -r sendgrid_api_key </dev/tty
            [ -n "$sendgrid_api_key" ] || printf "SendGrid API key (required): " >/dev/tty
          done
          printf "SendGrid from-email: " >/dev/tty
          while [ -z "$sendgrid_from_email" ]; do
            read -r sendgrid_from_email </dev/tty
            [ -n "$sendgrid_from_email" ] || printf "SendGrid from-email (required): " >/dev/tty
          done
          ;;
        2|ses|SES)
          email_provider="ses"
          printf "AWS SES region [us-east-1]: " >/dev/tty
          read -r ses_aws_region </dev/tty
          ses_aws_region="${ses_aws_region:-us-east-1}"
          printf "AWS access key ID: " >/dev/tty
          while [ -z "$aws_access_key_id" ]; do
            read -r aws_access_key_id </dev/tty
            [ -n "$aws_access_key_id" ] || printf "AWS access key ID (required): " >/dev/tty
          done
          printf "AWS secret access key: " >/dev/tty
          while [ -z "$aws_secret_access_key" ]; do
            read -r aws_secret_access_key </dev/tty
            [ -n "$aws_secret_access_key" ] || printf "AWS secret access key (required): " >/dev/tty
          done
          printf "SES from-email: " >/dev/tty
          while [ -z "$aws_ses_from_email" ]; do
            read -r aws_ses_from_email </dev/tty
            [ -n "$aws_ses_from_email" ] || printf "SES from-email (required): " >/dev/tty
          done
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
    echo "# Added by install.sh — trial deploy token + licensing portal, same values"
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
  ( cd "$GCP_DEPLOY_DIR" && ./scripts/self-deploy.sh "$gcp_env" )

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

  local portal_url_raw
  portal_url_raw=$(cd "${GCP_DEPLOY_DIR}/examples/self-deploy/cicd" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -raw portal_url 2>/dev/null || true)
  local portal_url="${portal_url_raw:-https://portal.${gcp_dns_zone}}"

  local ingress_ip
  ingress_ip=$(cd "${GCP_DEPLOY_DIR}/examples/self-deploy/root" && GOOGLE_APPLICATION_CREDENTIALS="$deployer_key" terraform output -raw nginx_ingress_ip 2>/dev/null || true)

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

  # Check for leftover artifacts from a previous GCP deploy run before asking
  # anything else — resuming skips straight past the docker/cloud choice and
  # every prompt in deploy_gcp, since all of that is already answered in the
  # env's existing tfvars. Deliberately doesn't try to guess whether that
  # prior run succeeded, failed, or is still stuck — the user already saw its
  # logs and knows better than any local-file heuristic could.
  local partial_env
  partial_env=$(detect_gcp_partial_deploy)
  if [ -n "$partial_env" ]; then
    echo "" >/dev/tty
    warn "Found previous run artifacts for GCP env '${partial_env}'." >/dev/tty
    printf "Retry that deploy, or start a new one? [retry/new] " >/dev/tty
    local resume_choice
    read -r resume_choice </dev/tty
    case "$resume_choice" in
      r|R|retry|Retry)
        check_gcp_requirements
        local tfvars_dir="${GCP_DEPLOY_DIR}/env"
        local tfvars_file="${tfvars_dir}/${partial_env}.tfvars"
        local resume_project_id
        local resume_dns_zone
        resume_project_id=$(grep -E '^project_id[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
        resume_dns_zone=$(grep -E '^dns_zone[[:space:]]*=' "$tfvars_file" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
        [ -n "$resume_project_id" ] || die "Could not read project_id back from ${tfvars_file} — fix or delete it and start a new deployment."
        deploy_gcp_run "$resume_project_id" "$partial_env" "$resume_dns_zone"
        return
        ;;
      *) info "Starting a new deployment." ;;
    esac
  fi

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
        if [ "$provider" = "gcp" ]; then
          check_gcp_requirements
          deploy_gcp "$token"
        else
          deploy_cloud "$token" "$provider"
        fi
      else
        echo ""
        die "CLI check failed. Fix your CLI auth and re-run the installer."
      fi
    fi
  fi
}

main "$@"
