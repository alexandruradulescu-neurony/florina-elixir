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

  @doc """
  Parse a value to an integer, or `nil` when it isn't one. Integers pass through;
  a binary must parse cleanly in full (no trailing characters); anything else is
  `nil`. Use for form/URL params compared against integer columns, where a
  non-integer must drop the filter rather than crash the query with a cast error.
  """
  def to_int(v) when is_integer(v), do: v

  def to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def to_int(_), do: nil
end
