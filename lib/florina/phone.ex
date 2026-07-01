defmodule Florina.Phone do
  @moduledoc """
  Phone-number normalization + matching for caller identification.

  There is no full libphonenumber-style parser here (no dependency, and stored
  numbers span formats: `+40 721 234 567`, `0721234567`, `0040721234567`).
  Instead we compare by the trailing significant digits: strip everything but
  digits and match on the last #{9}, so a caller ID in `+E.164` matches the same
  number stored in national/trunk form. That's enough to identify one of a
  tenant's handful of agents; the concierge still confirms identity by voice.
  """

  @match_len 9
  @min_digits 7

  @doc "Digits only (drops `+`, spaces, punctuation and a leading `00` intl prefix). `nil` if blank."
  def normalize(value) when is_binary(value) do
    digits =
      value
      |> String.replace(~r/\D/, "")
      |> String.replace_prefix("00", "")

    case digits do
      "" -> nil
      d -> d
    end
  end

  def normalize(_), do: nil

  @doc """
  A comparable key: the last #{@match_len} digits of the normalized number, so
  differing country/trunk prefixes still match. `nil` when there aren't enough
  digits to compare safely (avoids matching on a stray short string).
  """
  def match_key(value) do
    case normalize(value) do
      nil -> nil
      d when byte_size(d) < @min_digits -> nil
      d -> String.slice(d, -@match_len, @match_len)
    end
  end

  @doc "True if two phone numbers share the same trailing-digit key."
  def match?(a, b) do
    key = match_key(a)
    key != nil and key == match_key(b)
  end
end
