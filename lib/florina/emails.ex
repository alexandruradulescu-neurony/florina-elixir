defmodule Florina.Emails do
  @moduledoc """
  Builds and configures the voice concierge's outgoing follow-up emails.

  Guardrails (see the design doc §07): the model never supplies the recipient or a
  free-form body. The recipient is resolved server-side from the client's stored
  contact; the body comes from a fixed template per approved `purpose`, with the
  caller's short note slotted in. Sending uses the tenant's own SMTP settings.
  """
  import Swoosh.Email

  import Florina.Strings, only: [present?: 1]

  alias Florina.Emails.Draft
  alias Florina.TenantRepo

  @purposes ~w(follow_up summary materials)

  @doc "Approved email purposes (the only bodies the concierge can send)."
  def purposes, do: @purposes

  @doc """
  Persist a concierge email draft in the current tenant's schema, returning
  `{:ok, %Draft{}}` or `{:error, changeset}`. The recipient/notes/labels live here
  (never in the shared Oban args); `SendEmail` reloads by id.
  """
  def create_draft(attrs) do
    %Draft{} |> Draft.changeset(attrs) |> TenantRepo.insert()
  end

  @doc "Fetch a queued draft by id from the current tenant's schema, or `nil`."
  def get_draft(id), do: TenantRepo.get(Draft, id)

  @doc """
  The first usable contact email on record for a client, or `nil`. Recipients are
  only ever resolved from stored contacts — never model-supplied.
  """
  def recipient_for(%{contacts: contacts}) when is_list(contacts) do
    contacts
    |> Enum.map(&contact_email/1)
    |> Enum.find(fn e -> is_binary(e) and String.contains?(e, "@") end)
  end

  def recipient_for(_), do: nil

  defp contact_email(%{"email" => e}), do: e
  defp contact_email(%{email: e}), do: e
  defp contact_email(_), do: nil

  @doc "True when the tenant has enough SMTP config to send (host + from address)."
  def smtp_configured?(settings) do
    present?(settings.smtp_host) and present?(settings.smtp_from)
  end

  @doc """
  Build a Swoosh email for `purpose` to `to`, from the tenant's configured address.
  `{:ok, email}` or `{:error, :smtp_not_configured | :bad_purpose}`.
  """
  def build(settings, to, purpose, notes) when purpose in @purposes do
    if present?(settings.smtp_from) do
      from_name = settings.smtp_from_name || "Florina"
      {subject, body} = template(purpose, notes, from_name)

      email =
        new()
        |> to(to)
        |> from({from_name, settings.smtp_from})
        |> subject(subject)
        |> text_body(body)

      {:ok, email}
    else
      {:error, :smtp_not_configured}
    end
  end

  def build(_settings, _to, _purpose, _notes), do: {:error, :bad_purpose}

  @doc """
  Build the agent-facing concierge email: a recap/reminder for the caller about a
  meeting, with the client's materials attached. `context` carries `client_name`,
  `meeting_title`, `meeting_time`, `notes`, and `doc_names`; `attachments` is a
  list of `Swoosh.Attachment`. `{:ok, email}` or `{:error, :smtp_not_configured | :bad_purpose}`.
  """
  def build_agent_email(settings, to, purpose, context, attachments \\ [])

  def build_agent_email(settings, to, purpose, context, attachments) when purpose in @purposes do
    if present?(settings.smtp_from) do
      from_name = settings.smtp_from_name || "Florina"
      {subject, body} = agent_template(purpose, context, from_name)

      email =
        new()
        |> to(to)
        |> from({from_name, settings.smtp_from})
        |> subject(subject)
        |> text_body(body)

      {:ok, Enum.reduce(attachments, email, &attachment(&2, &1))}
    else
      {:error, :smtp_not_configured}
    end
  end

  def build_agent_email(_settings, _to, _purpose, _context, _attachments),
    do: {:error, :bad_purpose}

  # --- Agent-facing templates (Romanian) --------------------------------------

  defp agent_template("materials", ctx, from_name),
    do:
      {"Materiale — #{client_of(ctx)}",
       agent_body(ctx, "Atașat aveți materialele clientului pentru această întâlnire.", from_name)}

  defp agent_template("summary", ctx, from_name),
    do:
      {"Rezumat întâlnire — #{client_of(ctx)}",
       agent_body(ctx, "Un scurt rezumat al aspectelor discutate:", from_name)}

  defp agent_template("follow_up", ctx, from_name),
    do:
      {"Recapitulare — #{client_of(ctx)}",
       agent_body(ctx, "Aspecte de urmărit după discuția de azi:", from_name)}

  defp agent_body(ctx, lead, from_name) do
    meeting = meeting_line(ctx)
    notes = if present?(ctx["notes"]), do: "\n\n#{ctx["notes"]}", else: ""
    docs = doc_lines(ctx["doc_names"])

    "Bună ziua,\n\n#{lead}#{meeting}#{notes}#{docs}\n\n— #{from_name}"
  end

  defp meeting_line(ctx) do
    title = ctx["meeting_title"]
    time = ctx["meeting_time"]

    cond do
      present?(title) and present?(time) -> "\n\nÎntâlnire: #{title} (#{time})."
      present?(title) -> "\n\nÎntâlnire: #{title}."
      true -> ""
    end
  end

  defp doc_lines(names) when is_list(names) and names != [],
    do: "\n\nDocumente atașate:\n" <> Enum.map_join(names, "\n", &"- #{&1}")

  defp doc_lines(_), do: ""

  defp client_of(ctx),
    do: if(present?(ctx["client_name"]), do: ctx["client_name"], else: "client")

  @doc """
  Swoosh runtime config (relay + credentials) from the tenant's settings, passed to
  `Mailer.deliver/2`. TLS verification is lenient for now so it works against a
  tenant's own mail server; tighten to `:verify_peer` once the host's cert is known.
  """
  def smtp_config(settings) do
    [
      relay: settings.smtp_host,
      port: settings.smtp_port || 587,
      username: settings.smtp_username,
      password: settings.smtp_password,
      auth: :always,
      tls: :if_available,
      tls_options: [verify: :verify_none]
    ]
  end

  # --- Templates (Romanian, client-facing) -----------------------------------

  defp template("follow_up", notes, from_name) do
    {"Ca urmare a discuției noastre",
     body(notes, "Vă mulțumesc pentru timpul acordat.", from_name)}
  end

  defp template("summary", notes, from_name) do
    {"Rezumatul întâlnirii", body(notes, "Un scurt rezumat al discuției noastre:", from_name)}
  end

  defp template("materials", notes, from_name) do
    {"Materialele discutate", body(notes, "Vă transmit materialele discutate.", from_name)}
  end

  defp body(notes, fallback, from_name) do
    content = if present?(notes), do: notes, else: fallback
    "Bună ziua,\n\n#{content}\n\nCu stimă,\n#{from_name}"
  end
end
