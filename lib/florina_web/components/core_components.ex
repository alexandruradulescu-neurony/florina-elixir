defmodule FlorinaWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework.
  Components here are hand-written with plain Tailwind utilities (no component
  library) against the semantic color tokens defined in `assets/css/app.css`
  (`base-*`, `primary`, `error`, etc.). Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: FlorinaWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50"
      {@rest}
    >
      <div class={[
        "flex items-start gap-2 rounded-md p-4 text-sm shadow-lg ring-1 w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info &&
          "bg-blue-50 text-blue-800 ring-blue-600/10 dark:bg-blue-500/10 dark:text-blue-300 dark:ring-blue-400/20",
        @kind == :error &&
          "bg-red-50 text-red-800 ring-red-600/10 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-400/20"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    base =
      "inline-flex items-center justify-center gap-2 rounded-full px-4 py-2 text-sm font-semibold shadow-xs " <>
        "focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 cursor-pointer"

    variants = %{
      "primary" =>
        "bg-indigo-600 text-white hover:bg-indigo-500 focus-visible:outline-indigo-600 dark:bg-indigo-500 dark:hover:bg-indigo-400 dark:focus-visible:outline-indigo-500",
      nil =>
        "bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 focus-visible:outline-gray-400 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        [base, Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label for={@id} class="flex items-center gap-2 text-sm text-gray-900 dark:text-white">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={
            @class ||
              "size-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-600 dark:border-white/10 dark:bg-white/5"
          }
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm/6 font-medium text-gray-900 dark:text-white">
          {@label}
        </span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full rounded-md bg-white px-3 py-1.5 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500",
            @errors != [] && (@error_class || "outline-red-500 dark:outline-red-500")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm/6 font-medium text-gray-900 dark:text-white">
          {@label}
        </span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full min-h-24 rounded-md bg-white px-3 py-1.5 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500",
            @errors != [] && (@error_class || "outline-red-500 dark:outline-red-500")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-sm/6 font-medium text-gray-900 dark:text-white">
          {@label}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "w-full rounded-md bg-white px-3 py-1.5 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500",
            @errors != [] && (@error_class || "outline-red-500 dark:outline-red-500")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-red-600 dark:text-red-400">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders an editorial page header: an optional uppercase micro-label, a large
  Nunito-800 title, an optional subtitle, and optional right-aligned actions.
  """
  attr :micro, :string, default: nil, doc: "small uppercase eyebrow label above the title"
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-start justify-between gap-6", "mb-6"]}>
      <div>
        <p
          :if={@micro}
          class="mb-1.5 text-[10px] font-extrabold uppercase tracking-[0.14em] text-gray-500 dark:text-gray-400"
        >
          {@micro}
        </p>
        <h1 class="text-3xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-gray-500 dark:text-gray-400">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders an editorial stat card: a white hairline card with a small uppercase
  micro-label and a large tabular number, tinted by `tone`.

  ## Examples

      <.stat_card label="Completed" tone="green">42</.stat_card>
      <.stat_card label="Failed" tone="rose"><:meta>last 24h</:meta>3</.stat_card>
  """
  attr :label, :string, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral cyan green rose blue amber)
  slot :inner_block, required: true, doc: "the stat value (typically a number)"
  slot :meta, doc: "optional muted subtext under the number"

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-200 bg-white p-6 dark:border-white/10 dark:bg-white/5">
      <div class="text-[10px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
        {@label}
      </div>
      <div class={["mt-2 text-3xl font-extrabold tabular-nums tracking-tight", stat_tone(@tone)]}>
        {render_slot(@inner_block)}
      </div>
      <div :if={@meta != []} class="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {render_slot(@meta)}
      </div>
    </div>
    """
  end

  defp stat_tone("cyan"), do: "text-indigo-600 dark:text-indigo-400"
  defp stat_tone("green"), do: "text-green-600 dark:text-green-400"
  defp stat_tone("rose"), do: "text-rose-600 dark:text-rose-400"
  defp stat_tone("blue"), do: "text-blue-600 dark:text-blue-400"
  defp stat_tone("amber"), do: "text-amber-600 dark:text-amber-400"
  defp stat_tone(_neutral), do: "text-gray-900 dark:text-white"

  @doc """
  Canonical cell classes for editorial data tables — a 48px uppercase tracked
  header (`th_class/0`) and a 56px Nunito-Sans body cell (`td_class/0`). Used by
  the hand-written tables across the app so they share one density and treatment.
  """
  def th_class,
    do:
      "h-12 px-4 text-left text-[10px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400"

  def td_class,
    do: "h-14 px-4 align-middle font-tile text-sm font-semibold text-gray-700 dark:text-gray-300"

  @doc """
  Top-aligned body-cell variant of `td_class/0`, for dense tables whose rows
  carry multi-line content (transcripts, log payloads) and shouldn't be
  vertically centered.
  """
  def td_top_class,
    do: "px-4 py-3 align-top font-tile text-sm font-semibold text-gray-700 dark:text-gray-300"

  @doc "Human label for a visit status atom. One source of truth for every screen."
  def visit_status_label(:PLANNED), do: "Planned"
  def visit_status_label(:PRE_CALL_DONE), do: "Briefed"
  def visit_status_label(:IN_PROGRESS), do: "In progress"
  def visit_status_label(:POST_CALL_DONE), do: "Debriefed"
  def visit_status_label(:COMPLETE), do: "Complete"
  def visit_status_label(:CANCELLED), do: "Cancelled"
  def visit_status_label(:MISSED), do: "Missed"
  def visit_status_label(:ARCHIVED), do: "Archived"
  def visit_status_label(other), do: to_string(other)

  @doc "Tailwind chip classes for a visit status atom (shared so screens can't drift)."
  def visit_status_tone(:COMPLETE),
    do: "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400"

  def visit_status_tone(:IN_PROGRESS),
    do: "bg-blue-100 text-blue-700 dark:bg-blue-500/10 dark:text-blue-400"

  def visit_status_tone(s) when s in [:CANCELLED, :MISSED, :ARCHIVED],
    do: "bg-gray-100 text-gray-400 line-through dark:bg-white/5 dark:text-gray-500"

  def visit_status_tone(_),
    do: "bg-gray-100 text-gray-600 dark:bg-white/10 dark:text-gray-300"

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full text-left text-sm">
      <thead>
        <tr class="border-b border-gray-200 dark:border-white/10">
          <th :for={col <- @col} class="px-3 py-3.5 font-semibold text-gray-900 dark:text-white">
            {col[:label]}
          </th>
          <th :if={@action != []} class="px-3 py-3.5">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody
        id={@id}
        phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
        class="divide-y divide-gray-200 dark:divide-white/10"
      >
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="hover:bg-gray-50 dark:hover:bg-white/5"
        >
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={[
              "px-3 py-4 text-gray-700 dark:text-gray-300",
              @row_click && "hover:cursor-pointer"
            ]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 px-3 py-4 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-gray-200 dark:divide-white/10">
      <li :for={item <- @item} class="flex items-center gap-4 py-3">
        <div class="grow">
          <div class="font-semibold text-gray-900 dark:text-white">{item.title}</div>
          <div class="text-gray-700 dark:text-gray-300">{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(FlorinaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FlorinaWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
