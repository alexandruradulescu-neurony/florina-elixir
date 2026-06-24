defmodule FlorinaWeb.WhoamiController do
  @moduledoc "Throwaway diagnostic: shows the resolved tenant and a value from THEIR database."
  use FlorinaWeb, :controller
  import Ecto.Query, only: [from: 2]
  alias Florina.Tenants.Marker

  def show(conn, _params) do
    tenant = conn.assigns.tenant
    labels = Florina.TenantRepo.all(from m in Marker, select: m.label)
    text(conn, "tenant: #{tenant.slug} (#{tenant.name})\nmarkers: #{Enum.join(labels, ", ")}")
  end
end
