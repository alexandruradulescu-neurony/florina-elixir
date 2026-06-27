defmodule Florina.Integrations.CalendarProvider do
  @moduledoc "Read-calendar behaviour. Returns normalized event maps."
  alias Florina.OAuth.Credential

  @callback list_events(Credential.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | {:error, term}

  @doc """
  Fetch a single event by its provider id, for a just-before-dial freshness
  check. Returns `{:error, :not_found}` when the event was deleted; a returned
  event may carry `status: "cancelled"`.
  """
  @callback get_event(Credential.t(), String.t()) ::
              {:ok, map()} | {:error, :not_found} | {:error, term}
end
