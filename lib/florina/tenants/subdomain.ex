defmodule Florina.Tenants.Subdomain do
  @moduledoc """
  Extracts the tenant slug from a request host, given the base host.
  Only a single subdomain label directly left of the base host is accepted;
  anything else returns nil so resolution fails closed.
  """
  def extract(host, base) when is_binary(host) and is_binary(base) do
    case String.split(host, ".", parts: 2) do
      [sub, ^base] when sub != "" -> sub
      _ -> nil
    end
  end

  def extract(_host, _base), do: nil
end
