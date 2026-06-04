#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Florina Django systemd installer
# =============================================================================
# Run this on the server after provisioning/rebuild, before the first deploy,
# or whenever the service definitions change.
#
# Usage: DEPLOY_PATH=/home/USER/florina.vm.neurony.dev ./.deploy/install-systemd.sh
#        ./.deploy/install-systemd.sh /home/USER/florina.vm.neurony.dev
# =============================================================================

MODE="install"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
    shift
fi

DEPLOY_PATH="${DEPLOY_PATH:-${1:-}}"

if [ -z "$DEPLOY_PATH" ]; then
    echo "Error: DEPLOY_PATH is required"
    echo "Usage: DEPLOY_PATH=/path/to/app ./.deploy/install-systemd.sh"
    echo "   or: ./.deploy/install-systemd.sh /path/to/app"
    exit 1
fi

ENV_PATH="$DEPLOY_PATH/.env"
CURRENT_LINK="$DEPLOY_PATH/current"
LOG_DIR="$DEPLOY_PATH/logs"
DOMAIN="$(basename "$DEPLOY_PATH")"
BASE_SERVICE_NAME="${DOMAIN//./-}"
GUNICORN_SERVICE_NAME="${BASE_SERVICE_NAME}-gunicorn"
SCHEDULER_SERVICE_NAME="${BASE_SERVICE_NAME}-scheduler"
WSGI_MODULE="proj_mes_voice.wsgi:application"
SOCKET_PATH="/run/gunicorn/${BASE_SERVICE_NAME}.sock"
UV_BIN="${UV_BIN:-$HOME/.local/bin/uv}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ ! -d "$DEPLOY_PATH" ]; then
    log_error "Deploy path does not exist: $DEPLOY_PATH"
    exit 1
fi

if [ ! -f "$ENV_PATH" ]; then
    log_error "Expected .env file at $ENV_PATH"
    exit 1
fi

if [ ! -x "$UV_BIN" ] && ! command -v uv >/dev/null 2>&1; then
    log_error "uv is not installed yet. Install uv before installing systemd units."
    exit 1
fi

if [ ! -x "$UV_BIN" ]; then
    UV_BIN="$(command -v uv)"
fi

APP_USER="${APP_USER:-$(stat -c %U "$DEPLOY_PATH")}"
APP_GROUP="${APP_GROUP:-$(stat -c %G "$DEPLOY_PATH")}"

mkdir -p "$LOG_DIR"

GUNICORN_UNIT_PATH="/etc/systemd/system/${GUNICORN_SERVICE_NAME}.service"
SCHEDULER_UNIT_PATH="/etc/systemd/system/${SCHEDULER_SERVICE_NAME}.service"

if [ "$MODE" = "check" ]; then
    log_info "Checking Django Gunicorn service: $GUNICORN_SERVICE_NAME"
    if ! systemctl cat "$GUNICORN_SERVICE_NAME" >/dev/null 2>&1; then
        log_error "Missing systemd unit: $GUNICORN_SERVICE_NAME"
        log_error "Run manually once: DEPLOY_PATH=$DEPLOY_PATH bash $DEPLOY_PATH/current/.deploy/install-systemd.sh"
        exit 1
    fi

    log_info "Checking Django scheduler service: $SCHEDULER_SERVICE_NAME"
    if ! systemctl cat "$SCHEDULER_SERVICE_NAME" >/dev/null 2>&1; then
        log_error "Missing systemd unit: $SCHEDULER_SERVICE_NAME"
        log_error "Run manually once: DEPLOY_PATH=$DEPLOY_PATH bash $DEPLOY_PATH/current/.deploy/install-systemd.sh"
        exit 1
    fi

    log_info "Systemd units are installed"
    exit 0
fi

log_info "Installing Django Gunicorn service: $GUNICORN_SERVICE_NAME"
TMP_GUNICORN_UNIT="$(mktemp)"
cat > "$TMP_GUNICORN_UNIT" <<EOF
[Unit]
Description=Gunicorn (${DOMAIN})
After=network.target postgresql.service

[Service]
Type=notify
NotifyAccess=all
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${CURRENT_LINK}
EnvironmentFile=${ENV_PATH}
RuntimeDirectory=gunicorn
RuntimeDirectoryMode=0755
ExecStart=${UV_BIN} run gunicorn --workers ${GUNICORN_WORKERS} --timeout 300 --bind unix:${SOCKET_PATH} ${WSGI_MODULE}
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_DIR}/gunicorn.log
StandardError=append:${LOG_DIR}/gunicorn.error.log

[Install]
WantedBy=multi-user.target
EOF

log_info "Installing Django scheduler service: $SCHEDULER_SERVICE_NAME"
TMP_SCHEDULER_UNIT="$(mktemp)"
cat > "$TMP_SCHEDULER_UNIT" <<EOF
[Unit]
Description=APScheduler (${DOMAIN})
After=network.target postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${CURRENT_LINK}
EnvironmentFile=${ENV_PATH}
ExecStart=${UV_BIN} run python manage.py start_scheduler
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_DIR}/scheduler.log
StandardError=append:${LOG_DIR}/scheduler.error.log

[Install]
WantedBy=multi-user.target
EOF

sudo install -m 0644 "$TMP_GUNICORN_UNIT" "$GUNICORN_UNIT_PATH"
sudo install -m 0644 "$TMP_SCHEDULER_UNIT" "$SCHEDULER_UNIT_PATH"
rm -f "$TMP_GUNICORN_UNIT" "$TMP_SCHEDULER_UNIT"

sudo systemctl daemon-reload
sudo systemctl enable "$GUNICORN_SERVICE_NAME" >/dev/null
sudo systemctl enable "$SCHEDULER_SERVICE_NAME" >/dev/null

log_info "Installed ${GUNICORN_SERVICE_NAME}.service"
log_info "Installed ${SCHEDULER_SERVICE_NAME}.service"
