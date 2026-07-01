defmodule Florina.Emails do
  @moduledoc """
  Builds and configures the voice concierge's outgoing follow-up emails.

  Guardrails (see the design doc §07): the model never supplies the recipient or a
  free-form body. The recipient is resolved server-side from the client's stored
  contact; the body comes from a fixed template per approved `purpose`, with the
  caller's short note slotted in. Sending uses the tenant's own SMTP settings.
  """
  import Swoosh.Email

  @purposes ~w(follow_up summary materials)

  @doc "Approved email purposes (the only bodies the concierge can send)."
  def purposes, do: @purposes

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

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
