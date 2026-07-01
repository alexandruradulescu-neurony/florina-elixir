defmodule Florina.Services.Placeholders do
  @moduledoc """
  Placeholder rendering for the Auto Prompt Assembler.

  Substitutes `{placeholder}` tokens in a template string with values from a
  context map. Mirrors `voice/services/prompt_context.py :: render_placeholders`
  and the fencing helpers from the same file.

  Security properties (matching the Django implementation):
  - Uses `Regex.replace/3` with a function capture — never `String.replace/3`
    with evaluated format strings. Values are treated as opaque strings.
  - Untrusted text fields (manager notes, transcripts, client summaries) are
    wrapped with XML-style sentinel fences before substitution so the mega-prompt
    can tell Claude to treat those blocks as inert data.
  - Close-tag sequences (`</`) inside fenced values are defanged (`< /`) to
    prevent fence escaping from user-controlled input.
  - Fenced values are capped at 20 000 chars to bound LLM input cost.
  - Placeholders inside single-backtick spans are preserved verbatim (dial-time
    passthrough for ElevenLabs `format_prompt_for_visit`).
  - Unknown placeholder names are left unchanged in the output.

  ## Public API

      context = Florina.Services.Placeholders.build_pre_call_context(visit)
      rendered = Florina.Services.Placeholders.render(template, context)
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  # Fields whose values come from external/user-controlled sources and must be
  # wrapped in sentinel fences so Claude treats them as data, never instructions.
  @fenced_keys ~w(
    manager_notes
    visit_transcript
    client_summary
    client_lessons_learned
    client_documents
    interaction_history
    deal_history
    client_past_visits
    agent_recent_visits
    pre_call_brief
    new_post_call_summary
    current_lessons_learned
  )a

  # Per-fenced-field char cap. Generous enough for a long transcript but bounded.
  @max_fenced_chars 20_000

  # Strict placeholder pattern: {NAME} where NAME is [a-zA-Z_][a-zA-Z0-9_]*
  # Deliberately excludes dots, brackets, etc. — closes the format-string exploit
  # family (`{0.__class__.__base__.__subclasses__}`).
  @placeholder_re ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/

  # ---------------------------------------------------------------------------
  # Fence helpers
  # ---------------------------------------------------------------------------

  @doc false
  def fence(key, value) when is_binary(value) do
    if value == "" do
      ""
    else
      truncated =
        if byte_size(value) > @max_fenced_chars do
          String.slice(value, 0, @max_fenced_chars) <> "…[truncated]"
        else
          value
        end

      safe = String.replace(truncated, "</", "< /")
      tag = key |> to_string() |> String.upcase()
      "<#{tag}>\n#{safe}\n</#{tag}>"
    end
  end

  def fence(_key, _value), do: ""

  # Short, CRM-derived scalar identifiers (company name, industry) used inline in
  # sentences — sentinel-fencing them reads awkwardly, but they're still
  # attacker-influenced (Pipedrive), so we defang/flatten them instead of fencing.
  @sanitized_keys ~w(client_name client_industry)a

  @doc """
  Apply sentinel fences to the untrusted-text fields in `values`, and lightly
  sanitize short CRM scalar fields. Other fields pass through unchanged.
  """
  def apply_fences(values) when is_map(values) do
    Map.new(values, fn {k, v} ->
      cond do
        k in @fenced_keys and is_binary(v) -> {k, fence(k, v)}
        k in @sanitized_keys and is_binary(v) -> {k, sanitize_scalar(v)}
        true -> {k, v}
      end
    end)
  end

  @doc false
  # Neutralize injection vectors in short inline identifiers without fencing:
  # flatten control chars/newlines (so a value can't inject multi-line
  # instructions), defang fence-close sequences, and cap length.
  def sanitize_scalar(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
    |> String.replace("</", "< /")
    |> String.slice(0, 200)
    |> String.trim()
  end

  def sanitize_scalar(value), do: value

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Substitute `{placeholder}` tokens in `template` with values from `context`.

  - Placeholders inside single-backtick spans are preserved verbatim.
  - Unknown placeholder names are left unchanged and logged at warning level.
  - Values are coerced to string; `nil` becomes `""`.
  """
  def render(template, context) when is_binary(template) and is_map(context) do
    seen_unknown = :ets.new(:seen_unknown, [:set, :private])

    try do
      # Split on single backticks. Even-index parts are outside backticks
      # (substitute); odd-index parts are inside backticks (preserve as-is).
      parts = String.split(template, "`")

      substituted =
        parts
        |> Enum.with_index()
        |> Enum.map(fn {part, idx} ->
          if rem(idx, 2) == 0 do
            Regex.replace(@placeholder_re, part, fn _, name ->
              key = String.to_existing_atom(name)

              case Map.fetch(context, key) do
                {:ok, nil} ->
                  ""

                {:ok, val} ->
                  to_string(val)

                :error ->
                  # Try string key too
                  case Map.fetch(context, name) do
                    {:ok, nil} ->
                      ""

                    {:ok, val} ->
                      to_string(val)

                    :error ->
                      unless :ets.member(seen_unknown, name) do
                        :ets.insert(seen_unknown, {name, true})

                        Logger.warning(
                          "render_placeholders: unknown placeholder {#{name}} left untouched"
                        )
                      end

                      "{#{name}}"
                  end
              end
            end)
          else
            part
          end
        end)

      Enum.join(substituted, "`")
    rescue
      ArgumentError ->
        # String.to_existing_atom raised — atom not known, fall back gracefully
        render_with_string_keys(template, context)
    after
      :ets.delete(seen_unknown)
    end
  end

  # Fallback renderer that only uses string keys (avoids atom table pollution
  # for templates with placeholder names that have never been atomised).
  defp render_with_string_keys(template, context) do
    string_ctx =
      Map.new(context, fn {k, v} -> {to_string(k), v} end)

    parts = String.split(template, "`")

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, idx} ->
      if rem(idx, 2) == 0 do
        Regex.replace(@placeholder_re, part, fn _, name ->
          case Map.fetch(string_ctx, name) do
            {:ok, nil} ->
              ""

            {:ok, val} ->
              to_string(val)

            :error ->
              Logger.warning("render_placeholders: unknown placeholder {#{name}} left untouched")
              "{#{name}}"
          end
        end)
      else
        part
      end
    end)
    |> Enum.join("`")
  end
end
