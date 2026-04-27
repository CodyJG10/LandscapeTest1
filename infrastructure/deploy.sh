#!/usr/bin/env bash
# Full-stack deploy: Strapi backend (VPS) + Astro frontend (Cloudflare Workers or VPS)
# Usage: bash infrastructure/deploy.sh [--reconfigure]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
CF_DIR="$SCRIPT_DIR/cloudflare"
RECONFIGURE=false
FRONTEND_MODE=""

for arg in "$@"; do
  [[ "$arg" == "--reconfigure" ]] && RECONFIGURE=true
done

# ── helpers ───────────────────────────────────────────────────────────────────
step() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║  %-52s  ║\n" "$1"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
}

check_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' is required but not installed." >&2; exit 1; }
}

extract_var() {
  grep "^$1:" "$ANSIBLE_DIR/vars.yml" | head -1 | sed 's/^[^:]*: *//; s/"//g'
}

# ── prerequisites ─────────────────────────────────────────────────────────────
check_cmd ansible-playbook
check_cmd node
check_cmd npm
check_cmd openssl

# ── Step 1: Backend config ────────────────────────────────────────────────────
step "Step 1 — Backend configuration (Strapi)"

if [[ "$RECONFIGURE" == true ]] || [[ ! -f "$ANSIBLE_DIR/vars.yml" ]]; then
  [[ "$RECONFIGURE" == true && -f "$ANSIBLE_DIR/vars.yml" ]] && rm "$ANSIBLE_DIR/vars.yml"
  bash "$ANSIBLE_DIR/generate-vars.sh"
else
  echo "vars.yml already exists — skipping. Run with --reconfigure to redo."
fi

# ── Frontend hosting choice ───────────────────────────────────────────────────
echo ""
echo "How would you like to host the frontend?"
echo "  1) Cloudflare Workers  (serverless, global CDN)"
echo "  2) VPS                 (same server as Strapi)"
echo "  3) Skip                (backend only)"
read -rp "Choice [1]: " _fc
_fc="${_fc:-1}"
echo ""

case "$_fc" in
  1) FRONTEND_MODE="cloudflare" ;;
  2) FRONTEND_MODE="vps" ;;
  3) FRONTEND_MODE="skip" ;;
  *) echo "Invalid choice, defaulting to Cloudflare Workers." >&2; FRONTEND_MODE="cloudflare" ;;
esac

# ── Step 2: Frontend config ───────────────────────────────────────────────────
case "$FRONTEND_MODE" in
  cloudflare)
    step "Step 2 — Frontend configuration (Cloudflare Workers)"
    if [[ "$RECONFIGURE" == true ]] || [[ ! -f "$CF_DIR/vars.sh" ]]; then
      [[ "$RECONFIGURE" == true && -f "$CF_DIR/vars.sh" ]] && rm "$CF_DIR/vars.sh"
      bash "$CF_DIR/setup-cloudflare.sh"
    else
      echo "vars.sh already exists — skipping. Run with --reconfigure to redo."
    fi
    ;;
  vps)
    step "Step 2 — Frontend configuration (VPS)"
    if [[ "$RECONFIGURE" == true ]] || ! grep -q 'deploy_frontend_vps' "$ANSIBLE_DIR/vars.yml" 2>/dev/null; then
      bash "$ANSIBLE_DIR/setup-frontend-vps.sh"
    else
      echo "Frontend VPS config already in vars.yml — skipping. Run with --reconfigure to redo."
    fi
    ;;
  skip)
    echo "  Skipping frontend — backend only."
    ;;
esac

# ── Step 3: Deploy backend (+ VPS frontend via Ansible) ───────────────────────
step "Step 3 — Deploy backend to VPS"

read -rp "VPS IP address: " VPS_HOST
read -rp "VPS username [root]: " VPS_USER
VPS_USER="${VPS_USER:-root}"

echo ""
echo "Authentication:"
echo "  1) SSH key (recommended)"
echo "  2) Password"
read -rp "Choice [1]: " AUTH_CHOICE
AUTH_CHOICE="${AUTH_CHOICE:-1}"
echo ""

VPS_PASS=""
SSH_KEY=""
if [[ "$AUTH_CHOICE" == "1" ]]; then
  read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_ssh_private_key_file=$SSH_KEY"
else
  read -rsp "VPS password: " VPS_PASS; echo
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_password=$VPS_PASS"
fi

ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  "$ANSIBLE_DIR/deploy.yml" \
  -i "$ANSIBLE_DIR/inventory.example" \
  -e @"$ANSIBLE_DIR/vars.yml" \
  $ANSIBLE_CONN

# ── Step 4: Deploy Cloudflare frontend (if chosen) ────────────────────────────
if [[ "$FRONTEND_MODE" == "cloudflare" ]]; then
  step "Step 4 — Deploy frontend to Cloudflare Workers"
  bash "$CF_DIR/deploy.sh"
fi

# ── Step 5: GitHub Actions CI/CD setup ───────────────────────────────────────
step "Step 5 — GitHub Actions CI/CD"

SITE_NAME=$(extract_var site_name)
REPO_URL=$(extract_var repo_url | sed 's/\.git$//')
GH_REPO=$(echo "$REPO_URL" | sed 's|https://github.com/||')

_setup_gh_secrets() {
  local key_file="$1"

  echo "  Setting secrets on $GH_REPO ..."
  gh secret set VPS_HOST      --body "$VPS_HOST"  --repo "$GH_REPO"
  gh secret set VPS_USER      --body "$VPS_USER"  --repo "$GH_REPO"
  gh secret set VPS_SITE_NAME --body "$SITE_NAME" --repo "$GH_REPO"
  gh secret set VPS_SSH_KEY   < "$key_file"       --repo "$GH_REPO"

  echo ""
  echo "  Secrets set:"
  echo "    VPS_HOST       $VPS_HOST"
  echo "    VPS_USER       $VPS_USER"
  echo "    VPS_SITE_NAME  $SITE_NAME"
  echo "    VPS_SSH_KEY    (private key contents)"
}

_print_manual_instructions() {
  echo ""
  echo "  Add these secrets manually at:"
  echo "  $REPO_URL/settings/secrets/actions"
  echo ""
  echo "    VPS_HOST       $VPS_HOST"
  echo "    VPS_USER       $VPS_USER"
  echo "    VPS_SITE_NAME  $SITE_NAME"
  echo "    VPS_SSH_KEY    (contents of your SSH private key)"
}

if ! command -v gh &>/dev/null; then
  echo "  GitHub CLI (gh) not installed — cannot set secrets automatically."
  echo "  Install from https://cli.github.com/ and re-run to automate this step."
  _print_manual_instructions

elif ! gh auth status &>/dev/null 2>&1; then
  echo "  GitHub CLI is installed but not authenticated."
  echo "  Run: gh auth login"
  _print_manual_instructions

elif [[ "$AUTH_CHOICE" == "1" ]]; then
  # SSH key auth — use the key the user already has
  KEY_FILE="${SSH_KEY/#\~/$HOME}"
  if [[ -f "$KEY_FILE" ]]; then
    _setup_gh_secrets "$KEY_FILE"
  else
    echo "  SSH key not found at $SSH_KEY."
    _print_manual_instructions
  fi

else
  # Password auth — generate a dedicated ed25519 deploy key
  echo "  You connected with a password. CI/CD needs an SSH key."
  read -rp "  Generate a deploy key, install it on the VPS, and add to GitHub? [Y/n]: " _gk
  _gk="${_gk:-y}"
  if [[ "${_gk,,}" =~ ^y ]]; then
    DEPLOY_KEY_FILE="$(mktemp /tmp/forge_deploy_XXXXXX)"
    ssh-keygen -t ed25519 -C "forge-deploy@$SITE_NAME" -f "$DEPLOY_KEY_FILE" -N "" -q

    echo "  Installing public key on VPS ..."
    if command -v sshpass &>/dev/null; then
      sshpass -p "$VPS_PASS" ssh-copy-id \
        -i "${DEPLOY_KEY_FILE}.pub" \
        -o StrictHostKeyChecking=no \
        "$VPS_USER@$VPS_HOST"
    else
      echo "  (sshpass not found — copying key manually via SSH)"
      # shellcheck disable=SC2029
      ssh -o StrictHostKeyChecking=no "$VPS_USER@$VPS_HOST" \
        "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" \
        < "${DEPLOY_KEY_FILE}.pub"
    fi

    _setup_gh_secrets "$DEPLOY_KEY_FILE"
    rm -f "$DEPLOY_KEY_FILE" "${DEPLOY_KEY_FILE}.pub"
    echo "  Temporary key files removed."
  else
    _print_manual_instructions
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Deployment complete"

DOMAIN=$(extract_var domain_name)
echo "  Backend:   https://$DOMAIN"

case "$FRONTEND_MODE" in
  cloudflare)
    CF_PROJECT=$(grep 'CF_PROJECT_NAME=' "$CF_DIR/vars.sh" | head -1 | sed 's/^[^=]*=//; s/"//g')
    echo "  Frontend:  https://$CF_PROJECT.workers.dev"
    ;;
  vps)
    FRONTEND_DOMAIN=$(extract_var frontend_domain)
    echo "  Frontend:  https://$FRONTEND_DOMAIN"
    ;;
esac

echo "  Adminer:   http://$VPS_HOST (ADMINER_PORT in Backend/.env)"
echo ""
