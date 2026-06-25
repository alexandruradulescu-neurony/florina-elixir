defmodule Florina.Integrations.OAuthProvider do
  @moduledoc "Identity + token behaviour for an OAuth/OIDC provider (Google, Microsoft)."
  alias Florina.OAuth.Credential

  @type tokens :: %{
          required(:access_token) => String.t(),
          optional(:refresh_token) => String.t() | nil,
          optional(:expires_in) => integer() | nil,
          optional(:scope) => String.t(),
          optional(:id_token) => String.t() | nil
        }

  @type identity :: %{
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil,
          subject: String.t() | nil
        }

  @callback authorize_url(redirect_uri :: String.t(), state :: String.t()) :: String.t()
  @callback exchange_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, tokens} | {:error, term}
  @callback refresh_token(Credential.t()) ::
              {:ok, %{access_token: String.t(), expires_at: DateTime.t() | nil}} | {:error, term}
  @callback fetch_identity(tokens) :: {:ok, identity} | {:error, term}
end
