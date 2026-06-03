#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Florina Django Rollback Script
# =============================================================================
# Usage: DEPLOY_PATH=/home/USER/florina.vm.neurony.dev ./.deploy/rollback.sh
#        or: ./.deploy/rollback.sh /home/USER/florina.vm.neurony.dev
# =============================================================================

DEPLOY_PATH="${DEPLOY_PATH:-${1:-}}"

if [ -z "$DEPLOY_PATH" ]; then
    echo "Error: DEPLOY_PATH is required"
    echo "Usage: ./rollback.sh <deploy_path>"
    echo "   or: DEPLOY_PATH=/path/to/app ./rollback.sh"
    exit 1
fi

RELEASES_DIR="$DEPLOY_PATH/releases"
CURRENT_LINK="$DEPLOY_PATH/current"
PREVIOUS_LINK="$DEPLOY_PATH/previous"
DOMAIN="$(basename "$DEPLOY_PATH")"
BASE_SERVICE_NAME="${DOMAIN//./-}"
GUNICORN_SERVICE_NAME="${BASE_SERVICE_NAME}-gunicorn"
SCHEDULER_SERVICE_NAME="${BASE_SERVICE_NAME}-scheduler"
HEALTH_URL="http://127.0.0.1/healthz/"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ ! -L "$PREVIOUS_LINK" ]; then
    log_error "No previous release found. Cannot rollback."
    exit 1
fi

PREVIOUS_TARGET="$(readlink -f "$PREVIOUS_LINK")"
if [ ! -d "$PREVIOUS_TARGET" ]; then
    log_error "Previous release directory does not exist: $PREVIOUS_TARGET"
    exit 1
fi

CURRENT_TARGET=""
[ -L "$CURRENT_LINK" ] && CURRENT_TARGET="$(readlink -f "$CURRENT_LINK")"

log_info "Current release: ${CURRENT_TARGET:-none}"
log_info "Rolling back to: $PREVIOUS_TARGET"

log_info "Switching current symlink to previous release ..."
ln -sfn "$PREVIOUS_TARGET" "$CURRENT_LINK"

log_info "Updating previous symlink ..."
NEW_PREVIOUS=""
FOUND_TARGET=false
mapfile -t AVAILABLE_RELEASES < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
for RELEASE_DIR in "${AVAILABLE_RELEASES[@]}"; do
    if [ "$RELEASE_DIR" = "$PREVIOUS_TARGET" ]; then
        FOUND_TARGET=true
        continue
    fi
    if [ "$FOUND_TARGET" = true ]; then
        NEW_PREVIOUS="$RELEASE_DIR"
        break
    fi
done

if [ -n "$NEW_PREVIOUS" ]; then
    ln -sfn "$NEW_PREVIOUS" "$PREVIOUS_LINK"
    log_info "Previous symlink now points to: $NEW_PREVIOUS"
else
    rm -f "$PREVIOUS_LINK"
    log_warn "No older release available for previous symlink"
fi

log_info "Restarting services ..."
sudo systemctl restart "$GUNICORN_SERVICE_NAME"
sudo systemctl restart "$SCHEDULER_SERVICE_NAME"

sleep 3
log_info "Checking web health ..."
APP_HEALTHY=false
for _ in {1..15}; do
    if curl -sf -H "Host: ${DOMAIN}" "$HEALTH_URL" >/dev/null 2>&1; then
        APP_HEALTHY=true
        break
    fi
    sleep 2
done

if [ "$APP_HEALTHY" != true ]; then
    log_error "Health check failed after rollback!"
    sudo systemctl status "$GUNICORN_SERVICE_NAME" --no-pager || true
    sudo systemctl status "$SCHEDULER_SERVICE_NAME" --no-pager || true
    exit 1
fi

log_info "Rollback completed successfully!"
echo ""
sudo systemctl status "$GUNICORN_SERVICE_NAME" --no-pager | head -8
sudo systemctl status "$SCHEDULER_SERVICE_NAME" --no-pager | head -8
