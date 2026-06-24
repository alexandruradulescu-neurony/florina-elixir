defmodule Florina.Calls do
  @moduledoc "Context for the call real-time edge."
  alias Florina.Repo
  alias Florina.Calls.CallAttempt

  def get_by_external_id(nil), do: nil
  def get_by_external_id(external_id),
    do: Repo.get_by(CallAttempt, external_call_id: external_id)

  def get(id), do: Repo.get(CallAttempt, id)
end
