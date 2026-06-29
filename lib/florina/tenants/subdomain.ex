defmodule Florina.Tenants.Subdomain do
  @moduledoc """
  Extracts the tenant slug from a request host, given the base host.
  Only a single subdomain label directly left of the base host is accepted;
  anything else returns nil so resolution fails closed.
  """
  def extract(host, base) when is_binary(host) and is_binary(base) do
    # Hosts are case-insensitive; downcase both so `Acme.example.com` resolves to
    # the same (lowercase-stored) slug as `acme.example.com`.
    base_lc = String.downcase(base)

    case String.split(String.downcase(host), ".", parts: 2) do
      [sub, ^base_lc] when sub != "" -> sub
      _ -> nil
    end
  end

  def extract(_host, _base), do: nil
end
