#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Florina Django Deployment Script
# =============================================================================
# This script runs ON THE SERVER after the repo is cloned into a release dir.
# It installs dependencies with uv, runs Django checks/migrations/static build,
# maintains release symlinks, ensures systemd units are correct, and restarts
# both the Gunicorn web process and the APScheduler worker.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${DEPLOY_PATH:-}" ]; then
    DEPLOY_PATH="$(cd "$RELEASE_PATH/.." && pwd)"
fi

RELEASES_DIR="$DEPLOY_PATH/releases"
ENV_PATH="$DEPLOY_PATH/.env"
CURRENT_LINK="$DEPLOY_PATH/current"
PREVIOUS_LINK="$DEPLOY_PATH/previous"
LOG_DIR="$DEPLOY_PATH/logs"
MEDIA_DIR="$DEPLOY_PATH/media"
DOMAIN="$(basename "$DEPLOY_PATH")"
BASE_SERVICE_NAME="${DOMAIN//./-}"
GUNICORN_SERVICE_NAME="${BASE_SERVICE_NAME}-gunicorn"
SCHEDULER_SERVICE_NAME="${BASE_SERVICE_NAME}-scheduler"
HEALTH_URL="http://127.0.0.1/healthz/"
KEEP_RELEASES=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

require_file() {
    if [ ! -f "$1" ]; then
        log_error "$2"
        exit 1
    fi
}

restart_services() {
    log_info "Restarting $GUNICORN_SERVICE_NAME ..."
    sudo systemctl restart "$GUNICORN_SERVICE_NAME"

    log_info "Restarting $SCHEDULER_SERVICE_NAME ..."
    sudo systemctl restart "$SCHEDULER_SERVICE_NAME"
}

rollback_to_previous() {
    if [ ! -L "$PREVIOUS_LINK" ]; then
        log_error "No previous release available for rollback."
        return 1
    fi

    PREV="$(readlink -f "$PREVIOUS_LINK")"
    if [ -z "$PREV" ] || [ ! -d "$PREV" ]; then
        log_error "Previous release is invalid: $PREV"
        return 1
    fi

    log_warn "Rolling back current symlink to: $PREV"
    ln -sfn "$PREV" "$CURRENT_LINK"
    restart_services
}

log_info "Deploying repo release: $RELEASE_PATH"
log_info "Deploy root: $DEPLOY_PATH"
log_info "Domain: $DOMAIN"

require_file "$ENV_PATH" ".env file not found at $ENV_PATH"

mkdir -p "$RELEASES_DIR" "$LOG_DIR" "$MEDIA_DIR"

log_info "Linking shared .env and media into release ..."
ln -sfn "$ENV_PATH" "$RELEASE_PATH/.env"
rm -rf "$RELEASE_PATH/media"
ln -sfn "$MEDIA_DIR" "$RELEASE_PATH/media"

log_info "Ensuring systemd units are installed and current ..."
DEPLOY_PATH="$DEPLOY_PATH" bash "$RELEASE_PATH/.deploy/install-systemd.sh"

if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV_BIN="$HOME/.local/bin/uv"
else
    log_error "uv is not installed or not on PATH."
    exit 1
fi

cd "$RELEASE_PATH"

log_info "Creating/updating release virtual environment ..."
"$UV_BIN" venv

log_info "Installing locked Python dependencies ..."
"$UV_BIN" sync --locked

log_info "Running Django checks ..."
"$UV_BIN" run python manage.py check

log_info "Running Django migrations ..."
"$UV_BIN" run python manage.py migrate --noinput

log_info "Collecting static files ..."
"$UV_BIN" run python manage.py collectstatic --noinput

log_info "Compiling translation messages if available ..."
if command -v msgfmt >/dev/null 2>&1; then
    "$UV_BIN" run python manage.py compilemessages || log_warn "compilemessages failed; continuing"
else
    log_warn "msgfmt not found; skipping compilemessages"
fi

log_info "Updating release symlinks ..."
if [ -L "$CURRENT_LINK" ]; then
    PREVIOUS_TARGET="$(readlink -f "$CURRENT_LINK")"
    if [ -n "$PREVIOUS_TARGET" ] && [ -d "$PREVIOUS_TARGET" ]; then
        ln -sfn "$PREVIOUS_TARGET" "$PREVIOUS_LINK"
    fi
fi
ln -sfn "$RELEASE_PATH" "$CURRENT_LINK"

if ! restart_services; then
    log_error "Service restart failed after deploy."
    rollback_to_previous || true
    sudo systemctl status "$GUNICORN_SERVICE_NAME" --no-pager || true
    sudo systemctl status "$SCHEDULER_SERVICE_NAME" --no-pager || true
    exit 1
fi

sleep 3
log_info "Checking web health through local Nginx ..."
APP_HEALTHY=false
for _ in {1..15}; do
    if curl -sf -H "Host: ${DOMAIN}" "$HEALTH_URL" >/dev/null 2>&1; then
        APP_HEALTHY=true
        break
    fi
    sleep 2
done

if [ "$APP_HEALTHY" != true ]; then
    log_error "Health check failed after deploy."
    rollback_to_previous || true
    sudo systemctl status "$GUNICORN_SERVICE_NAME" --no-pager || true
    sudo systemctl status "$SCHEDULER_SERVICE_NAME" --no-pager || true
    exit 1
fi

log_info "Verifying services are active ..."
sudo systemctl is-active --quiet "$GUNICORN_SERVICE_NAME"
sudo systemctl is-active --quiet "$SCHEDULER_SERVICE_NAME"

log_info "Pruning old releases (keeping $KEEP_RELEASES) ..."
mapfile -t RELEASE_DIRS < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
CURRENT_RELEASE=""
PREVIOUS_RELEASE=""
[ -L "$CURRENT_LINK" ] && CURRENT_RELEASE="$(readlink -f "$CURRENT_LINK")"
[ -L "$PREVIOUS_LINK" ] && PREVIOUS_RELEASE="$(readlink -f "$PREVIOUS_LINK")"

COUNT=0
for DIR in "${RELEASE_DIRS[@]}"; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -le "$KEEP_RELEASES" ]; then
        continue
    fi
    if [ "$DIR" = "$CURRENT_RELEASE" ] || [ "$DIR" = "$PREVIOUS_RELEASE" ]; then
        continue
    fi
    rm -rf "$DIR"
done

log_info "Deployment complete!"
echo ""
sudo systemctl status "$GUNICORN_SERVICE_NAME" --no-pager | head -8
sudo systemctl status "$SCHEDULER_SERVICE_NAME" --no-pager | head -8
