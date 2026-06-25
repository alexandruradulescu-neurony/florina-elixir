defmodule Florina.Repo.Migrations.EncryptSensitiveFields do
  @moduledoc """
  Converts PII/secret columns from text/jsonb to bytea so Cloak (AES-GCM-256)
  can store ciphertext in them.

  All affected tables are EMPTY in every existing tenant at the time this
  migration runs, so the type change is a no-data conversion.

  PostgreSQL cannot automatically cast text → bytea or jsonb → bytea, and it
  also refuses to carry over a text/jsonb column default when changing to bytea.
  Strategy per column:
    1. DROP DEFAULT (Cloak provides defaults at the application layer, not the DB)
    2. ALTER TYPE … USING to change the type with an explicit cast expression
    3. SET NOT NULL to restore the constraint (the alter step may relax it)

  Tables and columns changed:
    voice_googleoauthcredential: token, refresh_token, client_secret
      :text  → :binary (bytea)

    voice_generationrun: claude_request, claude_response, error,
                         context_bundle, parsed_outputs
      :text / :map (jsonb)  → :binary (bytea)
  """
  use Ecto.Migration

  def up do
    # -------------------------------------------------------------------------
    # voice_googleoauthcredential — OAuth secrets (no DB-level defaults to drop)
    # -------------------------------------------------------------------------
    execute """
    ALTER TABLE voice_googleoauthcredential
      ALTER COLUMN token         TYPE bytea USING token::bytea,
      ALTER COLUMN refresh_token TYPE bytea USING refresh_token::bytea,
      ALTER COLUMN client_secret TYPE bytea USING client_secret::bytea
    """

    # -------------------------------------------------------------------------
    # voice_generationrun — generation-run PII
    # These columns were created with DEFAULT '' / DEFAULT '{}' in text/jsonb.
    # Must drop the defaults first, then retype.
    # -------------------------------------------------------------------------
    execute "ALTER TABLE voice_generationrun ALTER COLUMN claude_request  DROP DEFAULT"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN claude_response DROP DEFAULT"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN error           DROP DEFAULT"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN context_bundle  DROP DEFAULT"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN parsed_outputs  DROP DEFAULT"

    execute """
    ALTER TABLE voice_generationrun
      ALTER COLUMN claude_request  TYPE bytea USING claude_request::bytea,
      ALTER COLUMN claude_response TYPE bytea USING claude_response::bytea,
      ALTER COLUMN error           TYPE bytea USING error::bytea,
      ALTER COLUMN context_bundle  TYPE bytea USING context_bundle::text::bytea,
      ALTER COLUMN parsed_outputs  TYPE bytea USING parsed_outputs::text::bytea
    """

    # Restore NOT NULL (the USING alter may have relaxed it for empty rows)
    execute """
    ALTER TABLE voice_generationrun
      ALTER COLUMN claude_request  SET NOT NULL,
      ALTER COLUMN claude_response SET NOT NULL,
      ALTER COLUMN error           SET NOT NULL,
      ALTER COLUMN context_bundle  SET NOT NULL,
      ALTER COLUMN parsed_outputs  SET NOT NULL
    """
  end

  def down do
    # Restore text/jsonb columns and their original DB-level defaults
    execute """
    ALTER TABLE voice_googleoauthcredential
      ALTER COLUMN token         TYPE text USING convert_from(token, 'UTF8'),
      ALTER COLUMN refresh_token TYPE text USING convert_from(refresh_token, 'UTF8'),
      ALTER COLUMN client_secret TYPE text USING convert_from(client_secret, 'UTF8')
    """

    execute """
    ALTER TABLE voice_generationrun
      ALTER COLUMN claude_request  TYPE text  USING convert_from(claude_request,  'UTF8'),
      ALTER COLUMN claude_response TYPE text  USING convert_from(claude_response, 'UTF8'),
      ALTER COLUMN error           TYPE text  USING convert_from(error,           'UTF8'),
      ALTER COLUMN context_bundle  TYPE jsonb USING convert_from(context_bundle,  'UTF8')::jsonb,
      ALTER COLUMN parsed_outputs  TYPE jsonb USING convert_from(parsed_outputs,  'UTF8')::jsonb
    """

    execute "ALTER TABLE voice_generationrun ALTER COLUMN claude_request  SET DEFAULT ''"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN claude_response SET DEFAULT ''"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN error           SET DEFAULT ''"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN context_bundle  SET DEFAULT '{}'"
    execute "ALTER TABLE voice_generationrun ALTER COLUMN parsed_outputs  SET DEFAULT '{}'"
  end
end
