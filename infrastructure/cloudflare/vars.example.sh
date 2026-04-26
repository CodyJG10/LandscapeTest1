# Copy this file to vars.sh and fill in real values.
# vars.sh is in .gitignore — it contains secrets.
#
# Run cloudflare/setup-cloudflare.sh to generate this file interactively.

# ── Cloudflare credentials ─────────────────────────────────────────────────────
# Account ID: Cloudflare dashboard → right sidebar on any zone overview page
CF_ACCOUNT_ID="your-account-id"

# API Token: Cloudflare dashboard → My Profile → API Tokens
# Required permissions: Workers Scripts:Edit, Workers Routes:Edit, Account Settings:Read
CF_API_TOKEN="your-api-token"

# ── Project config ─────────────────────────────────────────────────────────────
# Name of the Cloudflare Worker (must be lowercase, hyphens allowed)
CF_PROJECT_NAME="my-client-site"

# ── Application environment variables ─────────────────────────────────────────
# Non-secret vars stored in wrangler.toml [vars] — visible in wrangler.toml
STRAPI_API_URL="https://api.example.com"

# Secret vars pushed via `wrangler secret put` — NOT stored in wrangler.toml
STRAPI_API_TOKEN="your-strapi-api-token"
