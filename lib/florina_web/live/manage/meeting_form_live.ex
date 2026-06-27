defmodule FlorinaWeb.Manage.MeetingFormLive do
  @moduledoc """
  Create or edit a meeting (visit) by hand — for meetings that don't come from a
  synced calendar. Captures who/with-whom/when plus the optional methodology and
  the manager notes that feed Florina's pre-call brief.

  Time is entered as date + start time + duration (stored as UTC start/end), which
  is simpler and more browser-portable than a single datetime field. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Accounts, Clients, Methodologies, Visits}

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:agents, Accounts.list_agents())
      |> assign(:clients, Clients.list())
      |> assign(:methodologies, Methodologies.list_active())

    case socket.assigns.live_action do
      :new ->
        {:ok, socket |> assign(:visit, nil) |> assign_form(new_fields())}

      :edit ->
        case Visits.get_with_associations(params["id"]) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Meeting not found.")
             |> push_navigate(to: "/t/#{socket.assigns.tenant.slug}/manage/meetings")}

          visit ->
            {:ok, socket |> assign(:visit, visit) |> assign_form(fields_from(visit))}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"meeting" => params}, socket),
    do: {:noreply, assign_form(socket, params)}

  def handle_event("save", %{"meeting" => params}, socket) do
    with {:ok, attrs} <- build_attrs(params),
         {:ok, visit} <- persist(socket.assigns.visit, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Meeting saved.")
       |> push_navigate(to: "/t/#{socket.assigns.tenant.slug}/manage/meetings/#{visit.id}")}
    else
      {:error, :invalid_datetime} ->
        {:noreply,
         socket |> assign_form(params) |> put_flash(:error, "Please set a valid date and time.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket |> assign_form(params) |> put_flash(:error, "Couldn't save: #{errors(cs)}")}
    end
  end

  defp persist(nil, attrs), do: Visits.create(attrs)
  defp persist(visit, attrs), do: Visits.update(visit, attrs)

  # Convert the date/time/duration inputs into UTC start/end + the rest of attrs.
  defp build_attrs(p) do
    with {:ok, date} <- Date.from_iso8601(to_string(p["date"])),
         {:ok, time} <- Time.from_iso8601(to_string(p["time"]) <> ":00"),
         {:ok, start_dt} <- DateTime.new(date, time, "Etc/UTC") do
      duration = to_int(p["duration"], 30)
      end_dt = DateTime.add(start_dt, duration * 60, :second)

      {:ok,
       %{
         "agent_id" => p["agent_id"],
         "client_id" => p["client_id"],
         "title" => p["title"],
         "methodology_id" => blank_to_nil(p["methodology_id"]),
         "manager_notes" => p["manager_notes"],
         "start_time" => start_dt,
         "end_time" => end_dt
       }}
    else
      _ -> {:error, :invalid_datetime}
    end
  end

  defp new_fields do
    %{
      "agent_id" => "",
      "client_id" => "",
      "title" => "",
      "methodology_id" => "",
      "manager_notes" => "",
      "date" => Date.to_iso8601(Date.utc_today()),
      "time" => "09:00",
      "duration" => "30"
    }
  end

  defp fields_from(v) do
    duration =
      if v.end_time && v.start_time,
        do: max(DateTime.diff(v.end_time, v.start_time, :second), 0) |> div(60),
        else: 30

    %{
      "agent_id" => v.agent_id,
      "client_id" => v.client_id,
      "title" => v.title,
      "methodology_id" => v.methodology_id,
      "manager_notes" => v.manager_notes || "",
      "date" => Date.to_iso8601(DateTime.to_date(v.start_time)),
      "time" => Calendar.strftime(v.start_time, "%H:%M"),
      "duration" => to_string(duration)
    }
  end

  defp assign_form(socket, fields), do: assign(socket, :form, to_form(fields, as: :meeting))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:meetings}
    >
      <div class="mb-6">
        <.link
          navigate={"/t/#{@tenant.slug}/manage/meetings"}
          class="text-sm text-base-content/60 hover:underline"
        >
          ← Meetings
        </.link>
        <h1 class="text-2xl font-semibold mt-1">
          {if @live_action == :new, do: "New meeting", else: "Edit meeting"}
        </h1>
      </div>

      <.form
        for={@form}
        id="meeting-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-5"
      >
        <.input
          field={@form[:agent_id]}
          type="select"
          label="Agent"
          prompt="Select an agent"
          options={Enum.map(@agents, &{agent_label(&1), &1.id})}
        />
        <.input
          field={@form[:client_id]}
          type="select"
          label="Client"
          prompt="Select a client"
          options={Enum.map(@clients, &{&1.name, &1.id})}
        />
        <.input field={@form[:title]} type="text" label="Title" />

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <.input field={@form[:date]} type="date" label="Date" />
          <.input field={@form[:time]} type="time" label="Start time" />
          <.input field={@form[:duration]} type="number" label="Duration (min)" min="5" max="480" />
        </div>

        <.input
          field={@form[:methodology_id]}
          type="select"
          label="Methodology (optional)"
          prompt="Use agent / system default"
          options={Enum.map(@methodologies, &{&1.name, &1.id})}
        />
        <.input
          field={@form[:manager_notes]}
          type="textarea"
          label="Manager notes (pre-call instructions for Florina)"
          rows="4"
        />

        <div class="flex gap-3">
          <.button type="submit" variant="primary">
            {if @live_action == :new, do: "Create meeting", else: "Save changes"}
          </.button>
          <.link
            navigate={"/t/#{@tenant.slug}/manage/meetings"}
            class="btn btn-ghost"
          >
            Cancel
          </.link>
        </div>
      </.form>
    </Layouts.agent_app>
    """
  end

  defp agent_label(%{first_name: f, last_name: l, email: e}) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end

  defp to_int(v, default) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
