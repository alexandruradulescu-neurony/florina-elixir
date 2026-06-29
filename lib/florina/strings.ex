defmodule Florina.Strings do
  @moduledoc """
  Small shared string helpers. Centralizes the "treat nil/blank as nothing"
  logic that was previously duplicated (and had drifted on whitespace handling)
  across the integration and settings modules.
  """

  @doc "True for nil and strings that are empty or whitespace-only."
  def blank?(nil), do: true
  def blank?(v) when is_binary(v), do: String.trim(v) == ""
  def blank?(_), do: false

  @doc "The opposite of `blank?/1`."
  def present?(v), do: not blank?(v)

  @doc """
  Trim a string and return `nil` if it is blank, otherwise the trimmed value.
  Non-binaries return `nil`.
  """
  def blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil
end
