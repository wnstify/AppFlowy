#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AppFlowy Cloud - Interactive Setup Script
# =============================================================================
# First run:  full interactive setup with prompts + .env generation
# Re-run:     upgrade mode — re-extract container assets, skip prompts
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$msg" "$default"
    else
        printf '%s: ' "$msg"
    fi
    read -r input
    eval "$var=\"\${input:-\$default}\""
}

prompt_secret() {
    local var="$1" msg="$2"
    printf '%s: ' "$msg"
    read -rs input
    printf '\n'
    eval "$var=\"\$input\""
}

prompt_yn() {
    local var="$1" msg="$2" default="${3:-n}"
    if [ "$default" = "y" ]; then
        printf '%s [Y/n]: ' "$msg"
    else
        printf '%s [y/N]: ' "$msg"
    fi
    read -r input
    input="${input:-$default}"
    case "$input" in
        [Yy]*) eval "$var=true" ;;
        *)     eval "$var=false" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || error "Docker is not installed."

if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose V2 is required. Install it with: https://docs.docker.com/compose/install/"
fi

if [ ! -f docker-compose.yml ]; then
    error "docker-compose.yml not found. Run this script from the repository root."
fi

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

if [ "$CURRENT_UID" -eq 0 ]; then
    warn "Running as root (UID=0). Containers will run as root inside."
    warn "It is recommended to run as a non-root user."
    printf 'Continue anyway? [y/N]: '
    read -r cont
    case "$cont" in
        [Yy]*) ;;
        *)     exit 1 ;;
    esac
fi

# ---------------------------------------------------------------------------
# 2. Detect mode (first-run vs upgrade)
# ---------------------------------------------------------------------------
UPGRADE_MODE=false
if [ -f .env ]; then
    info "Existing .env detected — running in upgrade mode."
    info "Stopping running containers..."
    docker compose down 2>/dev/null || true
    UPGRADE_MODE=true
else
    command -v openssl >/dev/null 2>&1 || error "openssl is required for password generation on first run."
fi

# ---------------------------------------------------------------------------
# 3. Interactive prompts (first-run only)
# ---------------------------------------------------------------------------
if [ "$UPGRADE_MODE" = false ]; then
    printf '\n\033[1m=== AppFlowy Cloud Setup ===\033[0m\n\n'

    # Domain
    prompt FQDN "Enter your domain (e.g., appflowy.example.com)"
    [ -z "$FQDN" ] && error "Domain is required."

    # Admin email
    prompt GOTRUE_ADMIN_EMAIL "Enter admin email"
    [ -z "$GOTRUE_ADMIN_EMAIL" ] && error "Admin email is required."

    # Admin password
    printf 'Enter admin password (press Enter to auto-generate): '
    read -rs GOTRUE_ADMIN_PASSWORD
    printf '\n'
    ADMIN_PW_GENERATED=false
    if [ -z "$GOTRUE_ADMIN_PASSWORD" ]; then
        GOTRUE_ADMIN_PASSWORD=$(openssl rand -hex 16)
        ADMIN_PW_GENERATED=true
        info "Admin password auto-generated."
    fi

    # SMTP
    prompt_yn CONFIGURE_SMTP "Configure SMTP for email notifications?"
    if [ "$CONFIGURE_SMTP" = true ]; then
        prompt SMTP_HOST "SMTP host"
        prompt SMTP_PORT "SMTP port" "465"
        prompt SMTP_USER "SMTP username"
        prompt_secret SMTP_PASS "SMTP password"
        prompt SMTP_SENDER "Sender email" "$SMTP_USER"

        SMTP_TLS_KIND="wrapper"
    else
        SMTP_HOST="smtp.example.com"
        SMTP_PORT="465"
        SMTP_USER="noreply@example.com"
        SMTP_PASS="smtp_password_placeholder"
        SMTP_SENDER="noreply@example.com"
        SMTP_TLS_KIND="wrapper"
    fi

    # Signup
    prompt_yn ENABLE_SIGNUP "Enable user signup?"
    if [ "$ENABLE_SIGNUP" = true ]; then
        GOTRUE_DISABLE_SIGNUP=false
    else
        GOTRUE_DISABLE_SIGNUP=true
    fi

    # Auto-confirm: if SMTP is not configured, enable autoconfirm so signup works without email
    if [ "$CONFIGURE_SMTP" = true ]; then
        GOTRUE_MAILER_AUTOCONFIRM=false
    else
        GOTRUE_MAILER_AUTOCONFIRM=true
    fi

    # Generate passwords
    info "Generating secure passwords..."
    POSTGRES_PASSWORD=$(openssl rand -hex 24)
    DRAGONFLY_PASSWORD=$(openssl rand -hex 24)
    MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)
    GOTRUE_JWT_SECRET=$(openssl rand -hex 32)
fi

# ---------------------------------------------------------------------------
# 4. Update UID/GID in docker-compose.yml
# ---------------------------------------------------------------------------
if grep -q 'user: "1000:1000"' docker-compose.yml && [ "$CURRENT_UID" != "1000" -o "$CURRENT_GID" != "1000" ]; then
    info "Updating UID/GID from 1000:1000 to ${CURRENT_UID}:${CURRENT_GID}..."
    sed -i "s/1000:1000/${CURRENT_UID}:${CURRENT_GID}/g" docker-compose.yml
    sed -i "s/uid=1000,gid=1000/uid=${CURRENT_UID},gid=${CURRENT_GID}/g" docker-compose.yml
fi

# ---------------------------------------------------------------------------
# 5. Validate config files
# ---------------------------------------------------------------------------
info "Validating config files..."

for conf in "angie/angie.conf" "appflowy-web/nginx.conf"; do
    if [ -d "$conf" ]; then
        error "'$conf' is a directory (likely from a failed Docker run). Remove it and restore the original file:
  rm -rf $conf
  git checkout -- $conf"
    fi
    if [ ! -f "$conf" ]; then
        error "'$conf' not found. This file ships with the repository."
    fi
done

# ---------------------------------------------------------------------------
# 6. Create data directories
# ---------------------------------------------------------------------------
info "Creating data directories..."
mkdir -p postgres-data dragonfly-data minio-data

# ---------------------------------------------------------------------------
# 7. Generate .env (first-run only — before pull to avoid compose warnings)
# ---------------------------------------------------------------------------
if [ "$UPGRADE_MODE" = false ]; then
    info "Generating .env..."

    cat > .env <<EOF
# =============================================================================
# AppFlowy Cloud - Security-Hardened Configuration
# =============================================================================
# Generated by setup.sh — $(date -u +"%Y-%m-%d %H:%M UTC")

# -----------------------------------------------------------------------------
# Domain / URL
# -----------------------------------------------------------------------------
FQDN=${FQDN}
SCHEME=https
WS_SCHEME=wss

APPFLOWY_BASE_URL=\${SCHEME}://\${FQDN}
APPFLOWY_WEBSOCKET_BASE_URL=\${WS_SCHEME}://\${FQDN}/ws/v2
APPFLOWY_WEB_URL=\${APPFLOWY_BASE_URL}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------
POSTGRES_USER=appflowy
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=appflowy
POSTGRES_PORT=5432
POSTGRES_HOST=postgres

APPFLOWY_DATABASE_URL=postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}
APPFLOWY_DATABASE_MAX_CONNECTIONS=40

# GoTrue database URL (requires search_path=auth)
GOTRUE_DATABASE_URL=postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}?search_path=auth

# -----------------------------------------------------------------------------
# Dragonfly (Redis-compatible cache, replaces Redis)
# -----------------------------------------------------------------------------
DRAGONFLY_PASSWORD=${DRAGONFLY_PASSWORD}

# Redis-compatible URI for all AppFlowy services
APPFLOWY_REDIS_URI=redis://default:\${DRAGONFLY_PASSWORD}@dragonfly:6379

# -----------------------------------------------------------------------------
# MinIO (S3-compatible object storage)
# -----------------------------------------------------------------------------
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

APPFLOWY_S3_USE_MINIO=true
APPFLOWY_S3_MINIO_URL=http://minio:9000
APPFLOWY_S3_CREATE_BUCKET=true
APPFLOWY_S3_ACCESS_KEY=\${MINIO_ROOT_USER}
APPFLOWY_S3_SECRET_KEY=\${MINIO_ROOT_PASSWORD}
APPFLOWY_S3_BUCKET=appflowy
APPFLOWY_S3_REGION=us-east-1
APPFLOWY_S3_PRESIGNED_URL_ENDPOINT=\${APPFLOWY_BASE_URL}/minio-api

# -----------------------------------------------------------------------------
# GoTrue Authentication
# -----------------------------------------------------------------------------
GOTRUE_ADMIN_EMAIL=${GOTRUE_ADMIN_EMAIL}
GOTRUE_ADMIN_PASSWORD=${GOTRUE_ADMIN_PASSWORD}

# JWT secret (MUST match across GoTrue and AppFlowy Cloud)
GOTRUE_JWT_SECRET=${GOTRUE_JWT_SECRET}
GOTRUE_JWT_EXP=604800

# Signup
GOTRUE_DISABLE_SIGNUP=${GOTRUE_DISABLE_SIGNUP}
GOTRUE_MAILER_AUTOCONFIRM=${GOTRUE_MAILER_AUTOCONFIRM}
GOTRUE_RATE_LIMIT_EMAIL_SENT=100

# GoTrue external URL (public-facing)
API_EXTERNAL_URL=\${APPFLOWY_BASE_URL}/gotrue

# GoTrue internal URL (container-to-container)
APPFLOWY_GOTRUE_BASE_URL=http://gotrue:9999

# -----------------------------------------------------------------------------
# SMTP (Email)
# -----------------------------------------------------------------------------
# GoTrue SMTP (auth emails)
GOTRUE_SMTP_HOST=${SMTP_HOST}
GOTRUE_SMTP_PORT=${SMTP_PORT}
GOTRUE_SMTP_USER=${SMTP_USER}
GOTRUE_SMTP_PASS=${SMTP_PASS}
GOTRUE_SMTP_ADMIN_EMAIL=${GOTRUE_ADMIN_EMAIL}

# AppFlowy Cloud SMTP (app emails)
APPFLOWY_MAILER_SMTP_HOST=${SMTP_HOST}
APPFLOWY_MAILER_SMTP_PORT=${SMTP_PORT}
APPFLOWY_MAILER_SMTP_USERNAME=${SMTP_USER}
APPFLOWY_MAILER_SMTP_EMAIL=${SMTP_SENDER}
APPFLOWY_MAILER_SMTP_PASSWORD=${SMTP_PASS}
APPFLOWY_MAILER_SMTP_TLS_KIND=${SMTP_TLS_KIND}

# -----------------------------------------------------------------------------
# OAuth Providers (optional, uncomment to enable)
# -----------------------------------------------------------------------------
GOTRUE_EXTERNAL_GOOGLE_ENABLED=false
# GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=
# GOTRUE_EXTERNAL_GOOGLE_SECRET=
# GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=\${API_EXTERNAL_URL}/callback

GOTRUE_EXTERNAL_GITHUB_ENABLED=false
# GOTRUE_EXTERNAL_GITHUB_CLIENT_ID=
# GOTRUE_EXTERNAL_GITHUB_SECRET=
# GOTRUE_EXTERNAL_GITHUB_REDIRECT_URI=\${API_EXTERNAL_URL}/callback

GOTRUE_EXTERNAL_DISCORD_ENABLED=false
# GOTRUE_EXTERNAL_DISCORD_CLIENT_ID=
# GOTRUE_EXTERNAL_DISCORD_SECRET=
# GOTRUE_EXTERNAL_DISCORD_REDIRECT_URI=\${API_EXTERNAL_URL}/callback

# -----------------------------------------------------------------------------
# Access Control
# -----------------------------------------------------------------------------
APPFLOWY_ACCESS_CONTROL=true
APPFLOWY_WEBSOCKET_MAILBOX_SIZE=6000

# -----------------------------------------------------------------------------
# Worker
# -----------------------------------------------------------------------------
APPFLOWY_WORKER_DATABASE_URL=\${APPFLOWY_DATABASE_URL}
APPFLOWY_WORKER_REDIS_URL=\${APPFLOWY_REDIS_URI}
APPFLOWY_WORKER_DATABASE_NAME=\${POSTGRES_DB}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
RUST_LOG=info

EOF

    chmod 600 .env
fi

# ---------------------------------------------------------------------------
# 8. Pull images
# ---------------------------------------------------------------------------
info "Pulling container images (this may take a few minutes)..."
docker compose pull

# ---------------------------------------------------------------------------
# 9. Extract container assets
# ---------------------------------------------------------------------------
info "Extracting container assets..."

# Clean old extracted assets
rm -rf appflowy-web-html appflowy-web-dist admin-frontend-app

# Read pinned image refs from docker-compose.yml
WEB_IMAGE=$(grep -oP 'image:\s+\Kappflowyinc/appflowy_web:\S+' docker-compose.yml)
ADMIN_IMAGE=$(grep -oP 'image:\s+\Kappflowyinc/admin_frontend:\S+' docker-compose.yml)

# AppFlowy Web
cid=$(docker create "$WEB_IMAGE")
docker cp "$cid:/usr/share/nginx/html" ./appflowy-web-html
docker cp "$cid:/app/dist" ./appflowy-web-dist
docker rm "$cid" >/dev/null

# Admin Frontend
cid=$(docker create "$ADMIN_IMAGE")
mkdir -p ./admin-frontend-app
docker cp "$cid:/app/." ./admin-frontend-app/
docker rm "$cid" >/dev/null

# ---------------------------------------------------------------------------
# 10. Set ownership
# ---------------------------------------------------------------------------
info "Setting ownership to ${CURRENT_UID}:${CURRENT_GID}..."
chown -R "${CURRENT_UID}:${CURRENT_GID}" \
    postgres-data dragonfly-data minio-data \
    appflowy-web-html appflowy-web-dist admin-frontend-app

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
printf '\n\033[1;32m========================================\033[0m\n'

if [ "$UPGRADE_MODE" = false ]; then
    printf '\033[1;32m  Setup complete!\033[0m\n'
    printf '\033[1;32m========================================\033[0m\n\n'

    printf '\033[1mGenerated credentials (save these — they will not be shown again):\033[0m\n'
    printf '  PostgreSQL password: %s\n' "$POSTGRES_PASSWORD"
    printf '  Dragonfly password:  %s\n' "$DRAGONFLY_PASSWORD"
    printf '  MinIO password:      %s\n' "$MINIO_ROOT_PASSWORD"
    printf '  JWT secret:          %s\n' "$GOTRUE_JWT_SECRET"
    if [ "$ADMIN_PW_GENERATED" = true ]; then
        printf '  Admin password:      %s\n' "$GOTRUE_ADMIN_PASSWORD"
    fi

    printf '\nConfiguration saved to: .env\n'
    printf '\n\033[1mNext steps:\033[0m\n'
    printf '  1. docker compose up -d\n'
    printf '  2. docker compose ps           # verify all healthy\n'
    printf '  3. Configure reverse proxy -> 127.0.0.1:8025\n\n'
else
    printf '\033[1;32m  Upgrade complete!\033[0m\n'
    printf '\033[1;32m========================================\033[0m\n\n'

    printf 'Container assets re-extracted from latest images.\n'
    printf 'Ownership set to %s:%s.\n' "$CURRENT_UID" "$CURRENT_GID"
    printf '\n\033[1mNext steps:\033[0m\n'
    printf '  1. docker compose up -d\n'
    printf '  2. docker compose ps\n\n'
fi
