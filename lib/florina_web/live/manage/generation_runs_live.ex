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
      <h1 class="text-2xl font-semibold mb-1 text-gray-900 dark:text-white">Generation Runs</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
        Every time Florina assembled a call script or distilled lessons.
      </p>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Domain</span>
          <select name="filters[domain]" class={sel()}>
            <option value="" selected={@filters["domain"] == ""}>All</option>
            <option :for={{v, l} <- domains()} value={v} selected={@filters["domain"] == v}>
              {l}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Outcome</span>
          <select name="filters[outcome]" class={sel()}>
            <option value="" selected={@filters["outcome"] == ""}>Any</option>
            <option value="success" selected={@filters["outcome"] == "success"}>Success</option>
            <option value="failures" selected={@filters["outcome"] == "failures"}>Failures</option>
          </select>
        </label>
        <button
          type="button"
          phx-click="clear"
          class="rounded-md px-3 py-1.5 text-sm font-semibold text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-white/10"
        >
          Clear
        </button>
      </.form>

      <div class="overflow-x-auto rounded-lg border border-gray-200 dark:border-white/10">
        <table class="w-full text-left text-sm">
          <thead class="bg-gray-50 dark:bg-white/5">
            <tr>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">When</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Domain</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Target</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Trigger</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Status</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Tokens</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@runs == []}>
              <td colspan="7" class="px-3 py-8 text-center text-gray-400">No runs found.</td>
            </tr>
            <tr :for={run <- @runs} class="border-t border-gray-200 dark:border-white/10">
              <td class="px-3 py-2 whitespace-nowrap text-gray-600 dark:text-gray-300">
                {time_label(run.created_at)}
              </td>
              <td class="px-3 py-2 text-gray-700 dark:text-gray-300">{domain_label(run.domain)}</td>
              <td class="px-3 py-2 text-gray-600 dark:text-gray-300">{target_label(run)}</td>
              <td class="px-3 py-2 text-gray-500 dark:text-gray-400">{run.triggered_by}</td>
              <td class="px-3 py-2">
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs font-medium",
                  (run.success &&
                     "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400") ||
                    "bg-red-100 text-red-700 dark:bg-red-500/10 dark:text-red-400"
                ]}>
                  {(run.success && "ok") || "fail"}
                </span>
              </td>
              <td class="px-3 py-2 text-gray-500 dark:text-gray-400">
                {run.input_tokens}/{run.output_tokens}
              </td>
              <td class="px-3 py-2 text-right">
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/generation-runs/#{run.id}"}
                  class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  View
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@pages > 1} class="flex items-center justify-between mt-4 text-sm">
        <span class="text-gray-500 dark:text-gray-400">Page {@page} of {@pages} · {@total} runs</span>
        <div class="flex gap-2">
          <button phx-click="page" phx-value-to={@page - 1} disabled={@page <= 1} class={pg_btn()}>
            ← Prev
          </button>
          <button
            phx-click="page"
            phx-value-to={@page + 1}
            disabled={@page >= @pages}
            class={pg_btn()}
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
          class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
        >
          ← Generation Runs
        </.link>
        <h1 class="text-2xl font-semibold mt-1 text-gray-900 dark:text-white">
          {domain_label(@run.domain)} · run #{@run.id}
        </h1>
        <p class="text-sm text-gray-500 dark:text-gray-400">
          {time_label(@run.created_at)} · {@run.triggered_by} ·
          <span class={[
            "rounded-full px-2 py-0.5 text-xs font-medium",
            (@run.success &&
               "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400") ||
              "bg-red-100 text-red-700 dark:bg-red-500/10 dark:text-red-400"
          ]}>
            {(@run.success && "ok") || "fail"}
          </span>
          · {@run.input_tokens}/{@run.output_tokens} tokens
        </p>
        <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">{target_label(@run)}</p>
      </div>

      <div
        :if={decrypted(@run.error) != ""}
        class="mb-6 rounded-lg border border-red-300 bg-red-50 p-4 dark:border-red-500/30 dark:bg-red-500/10"
      >
        <h2 class="text-sm font-semibold text-red-600 dark:text-red-400 mb-1">Error</h2>
        <pre class="whitespace-pre-wrap text-xs text-gray-700 dark:text-gray-300">{decrypted(@run.error)}</pre>
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
    <div class="rounded-lg border border-gray-200 dark:border-white/10">
      <div class="border-b border-gray-200 bg-gray-50 px-4 py-2 text-sm font-semibold text-gray-900 dark:border-white/10 dark:bg-white/5 dark:text-white">
        {@title}
      </div>
      <pre class="overflow-x-auto p-4 text-xs text-gray-700 dark:text-gray-300 whitespace-pre-wrap">{render_slot(@inner_block)}</pre>
    </div>
    """
  end

  # Shared TW Plus styling for filter selects and pagination buttons.
  defp sel,
    do:
      "rounded-md bg-white py-1.5 pl-3 pr-8 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"

  defp pg_btn,
    do:
      "rounded-md bg-white px-3 py-1.5 text-sm font-semibold text-gray-900 shadow-xs ring-1 ring-inset ring-gray-300 hover:bg-gray-50 disabled:opacity-50 cursor-pointer dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"

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

  defp time_label(%DateTime{} = dt),
    do: Calendar.strftime(Florina.Tz.local(dt), "%d %b %Y · %H:%M")

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
