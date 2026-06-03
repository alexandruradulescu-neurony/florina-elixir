"""
Webhook request authentication helpers.

Verifies that inbound webhook requests genuinely originate from the expected
third-party provider, before any state-changing processing happens.

- ElevenLabs: HMAC-SHA256 over "{timestamp}.{raw_body}" using the shared
  webhook secret (the `wsec_...` value), supplied in the `ElevenLabs-Signature`
  header as `t=<unix_ts>,v0=<hex_hmac>`. Includes a timestamp tolerance check
  to defeat replay attacks.
- Twilio: delegates to twilio.request_validator.RequestValidator (HMAC-SHA1 of
  the full URL + sorted POST params, keyed by the account auth token).

Design: fail-closed. If verification is required but the secret/token is not
configured, the caller rejects the request rather than trusting it.
"""

import hashlib
import hmac
import logging
import os
import time

from decouple import config

logger = logging.getLogger(__name__)

# Reject ElevenLabs webhooks whose signed timestamp is older/newer than this
# many seconds (replay-attack window). 30 minutes matches ElevenLabs guidance.
ELEVENLABS_TIMESTAMP_TOLERANCE = 30 * 60


def _resolve_secret(env_key: str) -> str:
    """Read a secret from env, falling back to .env directly.

    decouple.config prefers os.environ; if a parent shell exported the key as
    an empty string it would mask the real .env value, so we fall back to
    reading the .env file when the resolved value is blank.
    """
    value = (config(env_key, default="") or "").strip()
    if value:
        return value
    try:
        from decouple import RepositoryEnv

        env_path = os.path.join(os.getcwd(), ".env")
        if os.path.exists(env_path):
            return (RepositoryEnv(env_path).data.get(env_key) or "").strip()
    except Exception as e:  # pragma: no cover - defensive
        logger.warning(f"Could not read {env_key} from .env: {e}")
    return ""


def get_elevenlabs_webhook_secret() -> str:
    return _resolve_secret("ELEVENLABS_WEBHOOK_SECRET")


def get_twilio_auth_token() -> str:
    return _resolve_secret("TWILIO_AUTH_TOKEN")


def require_signature() -> bool:
    """Whether webhook signature verification is enforced (default: yes)."""
    return config("WEBHOOK_REQUIRE_SIGNATURE", default=True, cast=bool)


# ─────────────────────────────────────────────────────────────────────────────
# ElevenLabs
# ─────────────────────────────────────────────────────────────────────────────


def parse_elevenlabs_signature(header: str):
    """Parse 't=<ts>,v0=<hash>' → (timestamp_str, hash_hex). Missing parts None."""
    ts = sig = None
    for part in (header or "").split(","):
        part = part.strip()
        if part.startswith("t="):
            ts = part[2:].strip()
        elif part.startswith("v0="):
            sig = part[3:].strip()
    return ts, sig


def compute_elevenlabs_signature(timestamp: str, body: bytes, secret: str) -> str:
    """HMAC-SHA256 hex digest over '{timestamp}.{body}'."""
    if isinstance(body, str):
        body = body.encode("utf-8")
    signed_payload = f"{timestamp}.".encode() + body
    return hmac.new(secret.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()


def verify_elevenlabs_signature(
    signature_header: str,
    body: bytes,
    secret: str,
    tolerance: int = ELEVENLABS_TIMESTAMP_TOLERANCE,
    now: int = None,
):
    """Verify an ElevenLabs webhook signature.

    Returns (is_valid: bool, reason: str). reason is 'ok' on success, else a
    short machine-readable code suitable for logging (never includes secrets).
    """
    if not secret:
        return False, "no_secret"
    if not signature_header:
        return False, "missing_signature"

    ts, received = parse_elevenlabs_signature(signature_header)
    if not ts or not received:
        return False, "malformed_signature"

    try:
        ts_int = int(ts)
    except (ValueError, TypeError):
        return False, "bad_timestamp"

    current = int(time.time()) if now is None else now
    if abs(current - ts_int) > tolerance:
        return False, "expired"

    expected = compute_elevenlabs_signature(ts, body, secret)
    if not hmac.compare_digest(expected, received):
        return False, "mismatch"

    return True, "ok"


# ─────────────────────────────────────────────────────────────────────────────
# Twilio
# ─────────────────────────────────────────────────────────────────────────────


def verify_twilio_signature(url: str, post_params: dict, signature: str, auth_token: str):
    """Verify a Twilio webhook signature. Returns (is_valid, reason)."""
    if not auth_token:
        return False, "no_token"
    if not signature:
        return False, "missing_signature"
    try:
        from twilio.request_validator import RequestValidator
    except Exception as e:  # pragma: no cover
        logger.error(f"twilio package unavailable for signature validation: {e}")
        return False, "validator_unavailable"
    validator = RequestValidator(auth_token)
    if validator.validate(url, post_params, signature):
        return True, "ok"
    return False, "mismatch"
