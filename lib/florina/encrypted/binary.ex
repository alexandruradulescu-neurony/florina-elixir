defmodule Florina.Encrypted.Binary do
  @moduledoc """
  Ecto type that transparently encrypts/decrypts binary (string) fields via
  Florina.Vault (AES-GCM-256). Stored as :binary (bytea) in PostgreSQL.

  Use in schemas as:

      field :token, Florina.Encrypted.Binary
  """

  use Cloak.Ecto.Binary, vault: Florina.Vault
end
