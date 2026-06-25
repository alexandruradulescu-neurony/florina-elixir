defmodule Florina.Vault do
  @moduledoc """
  Cloak vault for field-level encryption at rest.

  All sensitive fields (OAuth tokens, generation-run PII) are encrypted using
  AES-GCM-256 before being stored in the database and decrypted transparently
  on read. The key is configured per environment:

    - dev/test: a fixed 32-byte key in config/dev.exs + config/test.exs
    - prod:     FIELD_ENCRYPTION_KEY env var (base64-encoded 32 bytes), read
                in config/runtime.exs

  To generate a fresh production key:

      :crypto.strong_rand_bytes(32) |> Base.encode64()
  """

  use Cloak.Vault, otp_app: :florina
end
