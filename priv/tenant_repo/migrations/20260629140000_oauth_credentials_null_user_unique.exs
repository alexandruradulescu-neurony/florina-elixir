defmodule Florina.TenantRepo.Migrations.OauthCredentialsNullUserUnique do
  use Ecto.Migration

  # The (provider, purpose, user_id) unique index does NOT constrain rows where
  # user_id IS NULL (Postgres treats NULLs as distinct). The future
  # `:florina_mailbox` purpose has no agent user (user_id NULL), so without this
  # partial index multiple mailbox credentials per provider could accumulate.
  # No-op today (no null-user rows exist yet); future-proofs that path.
  def change do
    create unique_index(:oauth_credentials, [:provider, :purpose],
             where: "user_id IS NULL",
             name: :oauth_credentials_provider_purpose_null_user_index
           )
  end
end
