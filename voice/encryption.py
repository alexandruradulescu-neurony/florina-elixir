"""
Field-level encryption at rest (Fernet / AES-128-CBC + HMAC).

Used to protect sensitive secrets stored in the DB — currently the Google OAuth
access token, refresh token, and client secret. Values are encrypted on write
and decrypted on read transparently via EncryptedTextField.

Key: FIELD_ENCRYPTION_KEY — a urlsafe-base64 32-byte Fernet key, or a
comma-separated list of keys to support rotation. The FIRST key encrypts; ALL
keys are tried on decryption. Generate one with:
    python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

Failure behavior is loud, not silent:
- Missing key -> ImproperlyConfigured.
- A stored value that looks like a Fernet token but cannot be decrypted with any
  configured key (wrong/rotated/corrupt key, or tampering) -> ImproperlyConfigured,
  rather than returning the ciphertext as if it were plaintext.
- Genuine legacy plaintext (pre-encryption, no Fernet prefix) is tolerated so the
  0015 data migration can encrypt existing rows.
"""

import logging

from cryptography.fernet import Fernet, InvalidToken, MultiFernet
from decouple import config
from django.core.exceptions import ImproperlyConfigured
from django.db import models

logger = logging.getLogger(__name__)

# Fernet tokens are urlsafe-base64 of a blob whose first byte is the version
# marker 0x80, so they always begin with "gAAAAA".
_FERNET_PREFIX = "gAAAAA"

_cipher = None


def get_cipher() -> MultiFernet:
    """Build a MultiFernet from FIELD_ENCRYPTION_KEY (one key or comma-separated).

    Rotation: prepend the new key, keep the old one until all rows are
    re-encrypted, then drop the old key.
    """
    global _cipher
    if _cipher is None:
        raw = (config("FIELD_ENCRYPTION_KEY", default="") or "").strip()
        keys = [k.strip() for k in raw.split(",") if k.strip()]
        if not keys:
            raise ImproperlyConfigured(
                "FIELD_ENCRYPTION_KEY is not set — required to read or write "
                "encrypted fields. Generate one with: "
                'python -c "from cryptography.fernet import Fernet; '
                'print(Fernet.generate_key().decode())"'
            )
        try:
            _cipher = MultiFernet([Fernet(k.encode()) for k in keys])
        except (ValueError, TypeError) as e:
            raise ImproperlyConfigured(f"FIELD_ENCRYPTION_KEY is malformed: {e}") from e
    return _cipher


def _looks_like_ciphertext(value: str) -> bool:
    return value.startswith(_FERNET_PREFIX)


class EncryptedTextField(models.TextField):
    """TextField whose value is encrypted at rest with Fernet.

    Encrypts on write, decrypts on read. Tolerates genuine legacy plaintext (so a
    data migration can encrypt existing rows) but fails loudly on ciphertext that
    cannot be decrypted, so a wrong/rotated key or tampering is never silently
    masked.
    """

    def from_db_value(self, value, expression, connection):
        if value is None or value == "":
            return value
        try:
            return get_cipher().decrypt(value.encode()).decode()
        except InvalidToken:
            if _looks_like_ciphertext(value):
                # Valid-looking ciphertext we cannot decrypt with any configured
                # key — wrong/rotated/corrupt key or tampering. Fail loud.
                logger.error(
                    "Failed to decrypt an encrypted field value — check "
                    "FIELD_ENCRYPTION_KEY (wrong, rotated, or value tampered)."
                )
                raise ImproperlyConfigured(
                    "Could not decrypt an encrypted field — FIELD_ENCRYPTION_KEY "
                    "may be wrong, rotated, or the stored value was tampered with."
                ) from None
            # Genuine legacy plaintext (not yet encrypted) — return as-is.
            return value

    def get_prep_value(self, value):
        value = super().get_prep_value(value)
        if value is None or value == "":
            return value
        if _looks_like_ciphertext(value):
            try:
                get_cipher().decrypt(value.encode())
                return value  # already ciphertext under a known key — keep as-is
            except InvalidToken:
                raise ImproperlyConfigured(
                    "Refusing to persist a ciphertext-like value that cannot be "
                    "decrypted with any configured FIELD_ENCRYPTION_KEY."
                ) from None
        return get_cipher().encrypt(value.encode()).decode()
