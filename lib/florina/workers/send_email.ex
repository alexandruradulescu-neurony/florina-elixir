defmodule Florina.Workers.SendEmail do
  @moduledoc """
  Delivers the concierge email — to the AGENT (the caller) — through the tenant's
  own SMTP settings. Queued by `draft_or_send_email` (which resolved the agent
  recipient), so this worker builds the agent-facing email, attaches the client's
  documents for the "materials" purpose, and sends. Audit-logged.

  Args: `tenant_slug`, `to` (agent email), `purpose`, `notes`, `agent_id`,
  `visit_id`, `client_id`, `client_name`, `meeting_title`, `meeting_time`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Florina.{Audit, Clients, Emails, Mailer, Settings, Storage, Tenants}
  alias Florina.Workers.Tenant

  # Bound what we attach so one huge/many documents can't blow the SMTP message.
  @max_attachments 5
  @max_attachment_bytes 10_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug} = args}) do
    case Tenant.pin_active(slug) do
      :skip ->
        Logger.info("[SendEmail] tenant=#{slug} not active — skipping")
        :ok

      :ok ->
        deliver(slug, args)
    end
  end

  defp deliver(slug, args) do
    settings = Settings.get()
    atts = attachment_data(slug, args)
    context = email_context(args, Enum.map(atts, & &1.filename))

    swoosh_atts =
      Enum.map(atts, fn a ->
        Swoosh.Attachment.new({:data, a.data}, filename: a.filename, content_type: a.content_type)
      end)

    with true <- Emails.smtp_configured?(settings),
         {:ok, email} <-
           Emails.build_agent_email(settings, args["to"], args["purpose"], context, swoosh_atts),
         {:ok, _meta} <- Mailer.deliver(email, Emails.smtp_config(settings)) do
      Audit.log(%{
        action: "voice.email_sent",
        user_id: to_int(args["agent_id"]),
        details: %{"visit_id" => args["visit_id"], "purpose" => args["purpose"]}
      })

      :ok
    else
      false ->
        # Permanent misconfiguration — cancel (don't burn retries) and record once.
        Logger.warning("[SendEmail] tenant=#{slug} SMTP not configured — cancelling")

        Audit.log(%{
          action: "voice.email_failed",
          level: :ERROR,
          details: %{"visit_id" => args["visit_id"], "reason" => "smtp_not_configured"}
        })

        {:cancel, :smtp_not_configured}

      other ->
        # Log by agent/visit, never the recipient address (PII discipline).
        Logger.error(
          "[SendEmail] tenant=#{slug} agent_id=#{args["agent_id"]} visit=#{args["visit_id"]} failed: #{inspect(other)}"
        )

        Audit.log(%{
          action: "voice.email_failed",
          level: :ERROR,
          details: %{"visit_id" => args["visit_id"], "purpose" => args["purpose"]}
        })

        {:error, :send_failed}
    end
  end

  # Read the client's documents into attachment tuples for the "materials" purpose
  # only. Defensive: skips missing/oversized files rather than failing the send.
  defp attachment_data(_slug, %{"purpose" => purpose}) when purpose != "materials", do: []

  defp attachment_data(slug, args) do
    with %{id: tenant_id} <- Tenants.get_by_slug(slug),
         client_id when is_integer(client_id) <- args["client_id"] do
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

  defp email_context(args, doc_names) do
    %{
      "client_name" => args["client_name"],
      "meeting_title" => args["meeting_title"],
      "meeting_time" => args["meeting_time"],
      "notes" => args["notes"],
      "doc_names" => doc_names
    }
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
