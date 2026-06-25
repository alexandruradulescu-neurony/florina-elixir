defmodule Florina.Authz do
  @moduledoc """
  Central role policy for the manager/agent split.

  ONE place decides what a signed-in user may see, so the rule can't drift
  between call sites. Every agent-facing list query passes `scope/1` to its
  context function:

    * `:all` — managers see the whole tenant
    * `{:own, user_id}` — agents see only their own records

  The scope is a *backend* filter (applied in the SQL `where`), not a UI toggle,
  so an agent can't reach a teammate's data by editing a URL or a form field.
  """
  alias Florina.Accounts.User

  @doc "True only for a tenant manager."
  def manager?(%User{role: :manager}), do: true
  def manager?(_), do: false

  @doc """
  Visibility scope for list queries derived from the signed-in user's role.

      iex> Florina.Authz.scope(%Florina.Accounts.User{role: :manager})
      :all

      iex> Florina.Authz.scope(%Florina.Accounts.User{id: 7, role: :agent})
      {:own, 7}
  """
  def scope(%User{role: :manager}), do: :all
  def scope(%User{id: id}) when is_integer(id), do: {:own, id}
end
