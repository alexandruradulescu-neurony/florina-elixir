defmodule Florina.Integrations.CalendarProvider do
  @moduledoc "Read-calendar behaviour. Returns normalized event maps."
  alias Florina.OAuth.Credential

  @callback list_events(Credential.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | {:error, term}
end
