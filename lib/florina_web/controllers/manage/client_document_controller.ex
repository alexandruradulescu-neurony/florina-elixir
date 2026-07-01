defmodule FlorinaWeb.Manage.ClientDocumentController do
  @moduledoc """
  Streams a client's uploaded document back to the browser as a download.

  Runs under the tenant-scoped, agent-authenticated pipeline, and additionally
  requires a manager. The document row is looked up in the pinned tenant schema
  and its `client_id` must match the URL, so one tenant (or one client) can never
  reach another's files. The bytes are served with an `attachment` disposition, so
  a document is never rendered inline in the browser.
  """
  use FlorinaWeb, :controller

  alias Florina.{Authz, Clients, Storage}

  def download(conn, %{"client_id" => client_id, "id" => id}) do
    with true <- Authz.manager?(conn.assigns[:current_agent]),
         %Clients.Document{} = doc <- Clients.get_document(id),
         true <- to_string(doc.client_id) == to_string(client_id),
         path <- Storage.file_path(conn.assigns.tenant.id, doc.client_id, doc.stored_filename),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type(doc.content_type || "application/octet-stream")
      |> send_download({:file, path}, filename: doc.original_filename)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
    end
  end
end
