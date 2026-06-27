defmodule FlorinaWeb.Manage.GenerationRunsLive do
  @moduledoc """
  Generation Runs — the audit trail of every Auto-Prompt-Assembler run.

  Index: paginated, filterable by domain and outcome (success/failures).
  Detail: the full run with its encrypted PII fields decrypted (context bundle,
  Claude request/response, parsed outputs). Opening a detail page is itself
  logged to the audit trail. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Audit, Prompts}

  @per_page 50

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns.live_action do
      :index ->
        {:ok,
         socket
         |> assign(:filters, %{"domain" => "", "outcome" => ""})
         |> assign(:page, 1)
         |> load_runs()}

      :show ->
        {:ok, mount_show(socket, params["id"])}
    end
  end

  defp mount_show(socket, id) do
    case Prompts.get_run(id) do
      nil ->
        socket
        |> put_flash(:error, "Generation run not found.")
        |> push_navigate(to: "/t/#{socket.assigns.tenant.slug}/manage/generation-runs")

      run ->
        # Reading decrypted PII is itself an audited action.
        Audit.log(%{
          action: "generation_run_viewed",
          user_id: socket.assigns.current_agent.id,
          visit_id: run.visit_id,
          details: %{"run_id" => run.id},
          level: :INFO
        })

        assign(socket, :run, run)
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket),
    do: {:noreply, socket |> assign(:filters, filters) |> assign(:page, 1) |> load_runs()}

  def handle_event("clear", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:filters, %{"domain" => "", "outcome" => ""})
       |> assign(:page, 1)
       |> load_runs()}

  def handle_event("page", %{"to" => to}, socket) do
    page = max(String.to_integer(to), 1)
    {:noreply, socket |> assign(:page, page) |> load_runs()}
  end

  defp load_runs(socket) do
    total = Prompts.count_runs(socket.assigns.filters)

    socket
    |> assign(:runs, Prompts.list_runs(socket.assigns.filters, socket.assigns.page, @per_page))
    |> assign(:total, total)
    |> assign(:pages, max(ceil(total / @per_page), 1))
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:generation_runs}
    >
      <h1 class="text-2xl font-semibold mb-1">Generation Runs</h1>
      <p class="text-sm text-base-content/60 mb-6">
        Every time Florina assembled a call script or distilled lessons.
      </p>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Domain</span>
          <select name="filters[domain]" class="select select-bordered select-sm">
            <option value="" selected={@filters["domain"] == ""}>All</option>
            <option :for={{v, l} <- domains()} value={v} selected={@filters["domain"] == v}>
              {l}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Outcome</span>
          <select name="filters[outcome]" class="select select-bordered select-sm">
            <option value="" selected={@filters["outcome"] == ""}>Any</option>
            <option value="success" selected={@filters["outcome"] == "success"}>Success</option>
            <option value="failures" selected={@filters["outcome"] == "failures"}>Failures</option>
          </select>
        </label>
        <button type="button" phx-click="clear" class="btn btn-ghost btn-sm">Clear</button>
      </.form>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-left text-sm">
          <thead class="bg-base-200">
            <tr>
              <th class="px-3 py-2 font-semibold">When</th>
              <th class="px-3 py-2 font-semibold">Domain</th>
              <th class="px-3 py-2 font-semibold">Target</th>
              <th class="px-3 py-2 font-semibold">Trigger</th>
              <th class="px-3 py-2 font-semibold">Status</th>
              <th class="px-3 py-2 font-semibold">Tokens</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@runs == []}>
              <td colspan="7" class="px-3 py-8 text-center text-base-content/50">No runs found.</td>
            </tr>
            <tr :for={run <- @runs} class="border-t border-base-300">
              <td class="px-3 py-2 whitespace-nowrap text-base-content/70">
                {time_label(run.created_at)}
              </td>
              <td class="px-3 py-2">{domain_label(run.domain)}</td>
              <td class="px-3 py-2 text-base-content/70">{target_label(run)}</td>
              <td class="px-3 py-2 text-base-content/60">{run.triggered_by}</td>
              <td class="px-3 py-2">
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs font-medium",
                  (run.success && "bg-success/10 text-success") || "bg-error/10 text-error"
                ]}>
                  {(run.success && "ok") || "fail"}
                </span>
              </td>
              <td class="px-3 py-2 text-base-content/60">{run.input_tokens}/{run.output_tokens}</td>
              <td class="px-3 py-2 text-right">
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/generation-runs/#{run.id}"}
                  class="text-xs text-primary hover:underline"
                >
                  View
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@pages > 1} class="flex items-center justify-between mt-4 text-sm">
        <span class="text-base-content/50">Page {@page} of {@pages} · {@total} runs</span>
        <div class="flex gap-2">
          <button
            phx-click="page"
            phx-value-to={@page - 1}
            disabled={@page <= 1}
            class="btn btn-sm"
          >
            ← Prev
          </button>
          <button
            phx-click="page"
            phx-value-to={@page + 1}
            disabled={@page >= @pages}
            class="btn btn-sm"
          >
            Next →
          </button>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:generation_runs}
    >
      <div class="mb-6">
        <.link
          navigate={"/t/#{@tenant.slug}/manage/generation-runs"}
          class="text-sm text-base-content/60 hover:underline"
        >
          ← Generation Runs
        </.link>
        <h1 class="text-2xl font-semibold mt-1">{domain_label(@run.domain)} · run #{@run.id}</h1>
        <p class="text-sm text-base-content/60">
          {time_label(@run.created_at)} · {@run.triggered_by} ·
          <span class={[
            "rounded-full px-2 py-0.5 text-xs font-medium",
            (@run.success && "bg-success/10 text-success") || "bg-error/10 text-error"
          ]}>
            {(@run.success && "ok") || "fail"}
          </span>
          · {@run.input_tokens}/{@run.output_tokens} tokens
        </p>
        <p class="text-sm text-base-content/60 mt-1">{target_label(@run)}</p>
      </div>

      <div
        :if={decrypted(@run.error) != ""}
        class="mb-6 rounded-lg border border-error/40 bg-error/5 p-4"
      >
        <h2 class="text-sm font-semibold text-error mb-1">Error</h2>
        <pre class="whitespace-pre-wrap text-xs text-base-content/80">{decrypted(@run.error)}</pre>
      </div>

      <div class="space-y-6">
        <.section title="Context bundle">{pretty(@run.context_bundle)}</.section>
        <.section title="Claude request">{decrypted(@run.claude_request)}</.section>
        <.section title="Claude response">{decrypted(@run.claude_response)}</.section>
        <.section title="Parsed outputs">{pretty(@run.parsed_outputs)}</.section>
      </div>
    </Layouts.agent_app>
    """
  end

  slot :inner_block, required: true
  attr :title, :string, required: true

  defp section(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300">
      <div class="border-b border-base-300 bg-base-200 px-4 py-2 text-sm font-semibold">{@title}</div>
      <pre class="overflow-x-auto p-4 text-xs text-base-content/80 whitespace-pre-wrap">{render_slot(@inner_block)}</pre>
    </div>
    """
  end

  defp domains do
    Enum.map(Florina.Enums.mega_prompt_domain_values(), fn {_k, v} -> {v, domain_label(v)} end)
  end

  defp domain_label(domain) do
    domain
    |> to_string()
    |> String.downcase()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp target_label(%{visit_id: vid}) when not is_nil(vid), do: "Visit ##{vid}"
  defp target_label(%{client_id: cid}) when not is_nil(cid), do: "Client ##{cid}"
  defp target_label(_), do: "—"

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y · %H:%M")
  defp time_label(_), do: "—"

  defp decrypted(v) when is_binary(v), do: v
  defp decrypted(_), do: ""

  defp pretty(map) when is_map(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(map)
    end
  end

  defp pretty(other), do: inspect(other)
end
