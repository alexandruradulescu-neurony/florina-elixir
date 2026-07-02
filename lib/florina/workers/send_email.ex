defmodule Florina.Workers.SendEmail do
  @moduledoc """
  Delivers the concierge email — to the AGENT (the caller) — through the tenant's
  own SMTP settings. Queued by `draft_or_send_email` (which resolved the agent
  recipient and persisted a per-tenant draft), so this worker loads the draft from
  the tenant schema, builds the agent-facing email, attaches the client's
  documents for the "materials" purpose, and sends. Audit-logged.

  Args: `tenant_slug`, `draft_id`. The recipient/notes/labels live in the tenant's
  `voice_email_draft` row — never in the shared public Oban args.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Florina.{Audit, Clients, Emails, Mailer, Settings, Storage, Tenants}
  alias Florina.Emails.Draft
  alias Florina.Workers.Tenant

  # Bound what we attach so one huge/many documents can't blow the SMTP message.
  @max_attachments 5
  @max_attachment_bytes 10_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug, "draft_id" => draft_id}}) do
    case Tenant.pin_active(slug) do
      :skip ->
        Logger.info("[SendEmail] tenant=#{slug} not active — skipping")
        :ok

      :ok ->
        case Emails.get_draft(draft_id) do
          %Draft{} = draft ->
            deliver(slug, draft)

          nil ->
            # Draft gone (tenant reset / manual delete) — nothing to send; don't retry.
            Logger.warning("[SendEmail] tenant=#{slug} draft=#{inspect(draft_id)} not found")
            {:cancel, :draft_not_found}
        end
    end
  end

  defp deliver(slug, %Draft{} = draft) do
    settings = Settings.get()
    atts = attachment_data(slug, draft)
    context = email_context(draft, Enum.map(atts, & &1.filename))

    swoosh_atts =
      Enum.map(atts, fn a ->
        Swoosh.Attachment.new({:data, a.data}, filename: a.filename, content_type: a.content_type)
      end)

    with true <- Emails.smtp_configured?(settings),
         {:ok, email} <-
           Emails.build_agent_email(
             settings,
             draft.recipient,
             draft.purpose,
             context,
             swoosh_atts
           ),
         {:ok, _meta} <- Mailer.deliver(email, Emails.smtp_config(settings)) do
      Audit.log(%{
        action: "voice.email_sent",
        user_id: draft.agent_id,
        details: %{"visit_id" => draft.visit_id, "purpose" => draft.purpose}
      })

      :ok
    else
      false ->
        # Permanent misconfiguration — cancel (don't burn retries) and record once.
        Logger.warning("[SendEmail] tenant=#{slug} SMTP not configured — cancelling")

        Audit.log(%{
          action: "voice.email_failed",
          level: :ERROR,
          details: %{"visit_id" => draft.visit_id, "reason" => "smtp_not_configured"}
        })

        {:cancel, :smtp_not_configured}

      other ->
        # Log by agent/visit, never the recipient address (PII discipline).
        Logger.error(
          "[SendEmail] tenant=#{slug} agent_id=#{draft.agent_id} visit=#{draft.visit_id} failed: #{inspect(other)}"
        )

        Audit.log(%{
          action: "voice.email_failed",
          level: :ERROR,
          details: %{"visit_id" => draft.visit_id, "purpose" => draft.purpose}
        })

        {:error, :send_failed}
    end
  end

  # Read the client's documents into attachment tuples for the "materials" purpose
  # only. Defensive: skips missing/oversized files rather than failing the send.
  defp attachment_data(_slug, %Draft{purpose: purpose}) when purpose != "materials", do: []

  defp attachment_data(slug, %Draft{} = draft) do
    with %{id: tenant_id} <- Tenants.get_by_slug(slug),
         client_id when is_integer(client_id) <- draft.client_id do
      client_id
      |> Clients.list_documents()
      |> Enum.filter(&(&1.byte_size in 1..@max_attachment_bytes))
      |> Enum.take(@max_attachments)
      |> Enum.flat_map(&read_attachment(tenant_id, client_id, &1))
    else
      _ -> []
    end
  end

  defp read_attachment(tenant_id, client_id, doc) do
    path = Storage.file_path(tenant_id, client_id, doc.stored_filename)

    case File.read(path) do
      {:ok, data} ->
        content_type = doc.content_type || MIME.from_path(doc.original_filename)
        [%{filename: doc.original_filename, content_type: content_type, data: data}]

      {:error, _} ->
        []
    end
  end

  defp email_context(%Draft{} = draft, doc_names) do
    %{
      "client_name" => draft.client_name,
      "meeting_title" => draft.meeting_title,
      "meeting_time" => draft.meeting_time,
      "notes" => draft.notes,
      "doc_names" => doc_names
    }
  end
end
