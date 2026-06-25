defmodule Florina.TenantRepo.Migrations.ReencryptGenerationrunPlaintext do
  @moduledoc """
  Repairs any `voice_generationrun` rows that `EncryptSensitiveFields`
  (20260625105445) may have corrupted by converting the PII columns to `bytea`
  with a raw `text::bytea` cast instead of Cloak ciphertext.

  The actual logic lives in `Florina.Prompts.GenerationRunReencryptor` (in `lib/`,
  so it's compiled and unit-tested). It is idempotent and a no-op on empty tables
  — every known environment had this table empty when the original migration ran,
  so in practice this changes nothing; it exists so a populated tenant, if any, is
  repaired rather than left silently unreadable.

  Runs only via the tenant migrator (boot / provision / migrate_tenants), all of
  which execute inside the running app, so `Florina.Vault` is already started.
  """
  use Ecto.Migration

  def up, do: Florina.Prompts.GenerationRunReencryptor.run(repo())

  def down, do: :ok
end
