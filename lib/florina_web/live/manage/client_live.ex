defmodule FlorinaWeb.Manage.ClientLive do
  @moduledoc """
  Manager create / edit / delete of a client, including its uploaded documents.
  Managers only.

  Create needs only a name — CRM ID is optional, so a manager can add a client by
  hand (CRM- and calendar-synced clients carry their own IDs). Documents (PDF, Word
  `.docx`, text/CSV) are attached on the edit screen: each is stored on the uploads
  volume, recorded as a row, and queued for background text extraction so Florina
  can read it during call-prep.

  Delete is guarded twice: the `visit → client` FK is `:restrict`, and the view
  also blocks deletion while the client still has meetings, so a client's history
  is never silently wiped. Deleting a client also removes its uploaded files.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Clients, Storage, Visits}
  alias Florina.Clients.Client
  alias Florina.Workers.ExtractDocumentText

  @status_options [{"New", :new}, {"Existing", :existing}]

  @max_entries 10
  @max_file_size 25_000_000

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :status_options, @status_options)

    case socket.assigns.live_action do
      :new ->
        {:ok,
         socket |> assign(:client, %Client{}) |> assign_form(Client.changeset(%Client{}, %{}))}

      :edit ->
        case Clients.get(params["id"]) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Client not found.")
             |> push_navigate(to: clients_path(socket))}

          client ->
            {:ok,
             socket
             |> assign(:client, client)
             |> assign(:documents, Clients.list_documents(client.id))
             |> assign_form(Client.changeset(client, %{}))
             |> allow_upload(:documents,
               accept: Storage.accepted_extensions(),
               max_entries: @max_entries,
               max_file_size: @max_file_size
             )}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset = socket.assigns.client |> Client.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case socket.assigns.live_action do
      :new -> create(socket, params)
      :edit -> update(socket, params)
    end
  end

  # phx-change target for the upload form — required so LiveView tracks selected
  # entries and surfaces per-file validation as they're chosen.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :documents, ref)}
  end

  def handle_event("upload_documents", _params, socket) do
    client = socket.assigns.client
    tenant = socket.assigns.tenant
    agent_id = socket.assigns.current_agent.id

    consumed =
      consume_uploaded_entries(socket, :documents, fn %{path: tmp_path}, entry ->
        stored = Storage.stored_filename(entry.client_name)
        Storage.store(tenant.id, client.id, tmp_path, stored)

        {:ok, doc} =
          Clients.create_document(%{
            client_id: client.id,
            original_filename: entry.client_name,
            stored_filename: stored,
            content_type: entry.client_type,
            byte_size: entry.client_size,
            uploaded_by_agent_id: agent_id
          })

        # Queue background text extraction so Florina can read the file.
        %{"tenant_slug" => tenant.slug, "document_id" => doc.id}
        |> ExtractDocumentText.new()
        |> Oban.insert()

        {:ok, doc.id}
      end)

    {:noreply,
     socket
     |> assign(:documents, Clients.list_documents(client.id))
     |> put_flash(:info, flash_for_upload(length(consumed)))}
  end

  def handle_event("delete_document", %{"id" => id}, socket) do
    client = socket.assigns.client
    doc = Clients.get_document(id)

    if doc && doc.client_id == client.id do
      Clients.delete_document(doc, socket.assigns.tenant.id)

      {:noreply,
       socket
       |> assign(:documents, Clients.list_documents(client.id))
       |> put_flash(:info, "File removed.")}
    else
      {:noreply, put_flash(socket, :error, "File not found.")}
    end
  end

  def handle_event("delete", _params, socket) do
    client = socket.assigns.client

    if Visits.list_for_client(client.id) == [] do
      case Clients.delete(client) do
        {:ok, _} ->
          # Row is gone (documents cascade); remove the client's files from disk too.
          Storage.delete_client_dir(socket.assigns.tenant.id, client.id)

          {:noreply,
           socket
           |> put_flash(:info, "Client deleted.")
           |> push_navigate(to: clients_path(socket))}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "This client still has history (calls or generation runs) — can't delete it."
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, "This client has meetings — delete or reassign those first.")}
    end
  end

  defp create(socket, params) do
    case Clients.create(params) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client created.")
         |> push_navigate(to: "#{clients_path(socket)}/#{client.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp update(socket, params) do
    case Clients.update(socket.assigns.client, params) do
      {:ok, client} ->
        {:noreply,
         socket
         |> assign(:client, client)
         |> assign_form(Client.changeset(client, %{}))
         |> put_flash(:info, "Client updated.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))
  defp clients_path(socket), do: "/t/#{socket.assigns.tenant.slug}/manage/clients"

  defp flash_for_upload(0), do: "No files were uploaded."
  defp flash_for_upload(1), do: "1 file uploaded."
  defp flash_for_upload(n), do: "#{n} files uploaded."

  # --- Document display helpers ---------------------------------------------

  defp status_label(:done), do: "Readable"
  defp status_label(:pending), do: "Processing…"
  defp status_label(:failed), do: "Couldn't read"
  defp status_label(:unsupported), do: "Not readable"
  defp status_label(_), do: "—"

  defp status_class(:done),
    do:
      "bg-emerald-50 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-500/10 dark:text-emerald-400"

  defp status_class(:pending),
    do: "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-500/10 dark:text-amber-400"

  defp status_class(:failed),
    do: "bg-rose-50 text-rose-700 ring-rose-600/20 dark:bg-rose-500/10 dark:text-rose-400"

  defp status_class(_),
    do: "bg-gray-100 text-gray-600 ring-gray-500/20 dark:bg-white/10 dark:text-gray-400"

  defp format_bytes(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)} MB"

  defp format_bytes(n) when is_integer(n) and n >= 1_000, do: "#{trunc(n / 1_000)} KB"
  defp format_bytes(n) when is_integer(n), do: "#{n} B"
  defp format_bytes(_), do: ""

  defp upload_error_to_string(:too_large), do: "too large (max 25 MB)"
  defp upload_error_to_string(:too_many_files), do: "too many files (max 10)"
  defp upload_error_to_string(:not_accepted), do: "unsupported type"
  defp upload_error_to_string(_), do: "could not be added"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:clients}
    >
      <div class="mb-6">
        <.link
          navigate={"/t/#{@tenant.slug}/manage/clients"}
          class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
        >
          ← Clients
        </.link>
        <h1 class="mt-2 text-3xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          {if @live_action == :new, do: "New client", else: @client.name}
        </h1>
      </div>

      <.form
        for={@form}
        id="client-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-5"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input
          :if={@live_action == :new}
          field={@form[:crm_id]}
          type="text"
          label="CRM ID (optional)"
        />
        <.input field={@form[:domain]} type="text" label="Domain" />
        <.input field={@form[:industry]} type="text" label="Industry" />
        <.input field={@form[:status]} type="select" label="Status" options={@status_options} />
        <.input field={@form[:ai_summary]} type="textarea" label="AI summary" rows="3" />
        <.input field={@form[:lessons_learned]} type="textarea" label="Lessons learned" rows="4" />
        <.button type="submit" variant="primary">
          {if @live_action == :new, do: "Create client", else: "Save changes"}
        </.button>
      </.form>

      <section :if={@live_action == :edit} class="max-w-2xl mt-10">
        <h2 class="text-sm font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
          Documents
        </h2>
        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
          Upload PDF, Word (.docx), or text/CSV files. Florina reads them to prepare this
          client's calls. Old .doc files aren't readable — save them as .docx first.
        </p>

        <ul
          :if={@documents != []}
          class="mt-4 divide-y divide-gray-200 rounded-lg border border-gray-200 dark:divide-white/10 dark:border-white/10"
        >
          <li
            :for={doc <- @documents}
            class="flex items-center justify-between gap-4 px-4 py-3"
          >
            <div class="min-w-0">
              <a
                href={~p"/t/#{@tenant.slug}/manage/clients/#{@client.id}/documents/#{doc.id}"}
                download
                class="block truncate text-sm font-semibold text-indigo-600 hover:underline dark:text-indigo-400"
              >
                {doc.original_filename}
              </a>
              <div class="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                {format_bytes(doc.byte_size)} · {Calendar.strftime(doc.created_at, "%d %b %Y")}
              </div>
            </div>
            <div class="flex shrink-0 items-center gap-3">
              <span class={[
                "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold ring-1 ring-inset",
                status_class(doc.extraction_status)
              ]}>
                {status_label(doc.extraction_status)}
              </span>
              <button
                type="button"
                phx-click="delete_document"
                phx-value-id={doc.id}
                data-confirm={"Remove #{doc.original_filename}?"}
                class="text-xs font-medium text-red-600 hover:text-red-500 dark:text-red-400"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>

        <p :if={@documents == []} class="mt-4 text-sm text-gray-500 dark:text-gray-400">
          No documents yet.
        </p>

        <form
          id="doc-upload-form"
          phx-change="validate_upload"
          phx-submit="upload_documents"
          class="mt-4"
        >
          <div
            phx-drop-target={@uploads.documents.ref}
            class="rounded-lg border border-dashed border-gray-300 p-6 text-center dark:border-white/15"
          >
            <.live_file_input upload={@uploads.documents} class="sr-only" />
            <label
              for={@uploads.documents.ref}
              class="cursor-pointer text-sm font-semibold text-indigo-600 hover:underline dark:text-indigo-400"
            >
              Choose files
            </label>
            <span class="text-sm text-gray-500 dark:text-gray-400">or drag and drop here</span>
            <p class="mt-1 text-xs text-gray-400 dark:text-gray-500">
              Up to 10 files, 25 MB each.
            </p>
          </div>

          <div :for={entry <- @uploads.documents.entries} class="mt-3">
            <div class="flex items-center justify-between gap-3 text-sm">
              <span class="min-w-0 truncate text-gray-700 dark:text-gray-300">
                {entry.client_name}
              </span>
              <div class="flex shrink-0 items-center gap-2">
                <span class="text-xs text-gray-500 dark:text-gray-400">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="text-gray-400 hover:text-red-600"
                  aria-label="cancel"
                >
                  ×
                </button>
              </div>
            </div>
            <p
              :for={err <- upload_errors(@uploads.documents, entry)}
              class="mt-1 text-xs text-red-600 dark:text-red-400"
            >
              {entry.client_name}: {upload_error_to_string(err)}
            </p>
          </div>

          <p
            :for={err <- upload_errors(@uploads.documents)}
            class="mt-2 text-xs text-red-600 dark:text-red-400"
          >
            {upload_error_to_string(err)}
          </p>

          <.button
            :if={@uploads.documents.entries != []}
            type="submit"
            variant="primary"
            class="mt-3"
          >
            Upload
          </.button>
        </form>
      </section>

      <div
        :if={@live_action == :edit}
        class="max-w-2xl mt-10 rounded-lg border border-red-300 p-5 dark:border-red-500/30"
      >
        <h2 class="text-sm font-semibold text-red-600 dark:text-red-400 mb-1">Danger zone</h2>
        <p class="text-xs text-gray-500 dark:text-gray-400 mb-3">
          Deleting a client is permanent and removes its uploaded files. It's blocked while
          the client still has meetings.
        </p>
        <button
          phx-click="delete"
          data-confirm={"Delete #{@client.name}? This can't be undone."}
          class="text-sm font-medium text-red-600 hover:text-red-500 dark:text-red-400"
        >
          Delete client
        </button>
      </div>
    </Layouts.agent_app>
    """
  end
end
