#!/bin/sh
# Container entrypoint: make the mounted uploads volume writable by the app.
#
# Railway mounts the /data volume owned by root, but the app runs as the
# unprivileged "nobody" user (see Dockerfile). This runs as root just long
# enough to hand /data to that user, then drops privileges and starts the
# server — so the app process itself stays unprivileged.
#
# Best-effort and always-boots: the chown is guarded, and if no privilege-drop
# tool is available we still start (as root) rather than failing to boot.

mkdir -p /data 2>/dev/null || true
chown nobody:nogroup /data 2>/dev/null || true

if command -v setpriv >/dev/null 2>&1; then
  exec setpriv --reuid nobody --regid nogroup --init-groups -- "$@"
elif command -v gosu >/dev/null 2>&1; then
  exec gosu nobody "$@"
else
  exec "$@"
fi
