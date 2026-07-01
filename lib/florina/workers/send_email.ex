defmodule Florina.Workers.SendEmail do
  @moduledoc """
  Delivers a concierge follow-up email through the tenant's own SMTP settings.

  Queued by the `draft_or_send_email` tool (which already resolved and validated
  the recipient), so this worker just builds the templated email and sends it —
  keeping the tool's response instant. The send + any failure are audit-logged.

  Args: `tenant_slug`, `client_id`, `to`, `purpose`, `notes`, `agent_id`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Florina.{Audit, Emails, Mailer, Settings}
  alias Florina.Workers.Tenant

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
    to = args["to"]
    purpose = args["purpose"]
    settings = Settings.get()

    with true <- Emails.smtp_configured?(settings),
         {:ok, email} <- Emails.build(settings, to, purpose, args["notes"]),
         {:ok, _meta} <- Mailer.deliver(email, Emails.smtp_config(settings)) do
      Audit.log(%{
        action: "voice.email_sent",
        user_id: to_int(args["agent_id"]),
        details: %{"to" => to, "purpose" => purpose, "client_id" => args["client_id"]}
      })

      :ok
    else
      other ->
        Logger.error("[SendEmail] tenant=#{slug} to=#{to} failed: #{inspect(other)}")

        Audit.log(%{
          action: "voice.email_failed",
          level: :ERROR,
          details: %{"to" => to, "purpose" => purpose}
        })

        {:error, :send_failed}
    end
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
