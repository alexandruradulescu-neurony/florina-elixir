defmodule Florina.Encrypted.Map do
  @moduledoc """
  Ecto type that transparently encrypts/decrypts map (JSONB) fields via
  Florina.Vault (AES-GCM-256). The map is JSON-serialised before encryption
  and stored as :binary (bytea) in PostgreSQL.

  Use in schemas as:

      field :context_bundle, Florina.Encrypted.Map
  """

  use Cloak.Ecto.Map, vault: Florina.Vault
end
