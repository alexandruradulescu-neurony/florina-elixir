defmodule Florina.Strings do
  @moduledoc """
  Small shared string helpers for treating nil/blank as nothing,
  used across the integration and settings modules.
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

  @doc """
  Like `to_int/1` but returns `default` instead of `nil` when the value isn't a
  clean integer. For form params that must fall back to a sensible number.
  """
  def to_int(v, default), do: to_int(v) || default

  @doc """
  The lowercased domain part of an email (everything after the last `@`), or
  `nil` when `email` isn't a binary or has no non-blank domain. The single source
  of truth for turning an email address into a bare domain.
  """
  def email_domain(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.last()
    |> to_string()
    |> String.downcase()
    |> blank_to_nil()
  end

  def email_domain(_), do: nil
end
