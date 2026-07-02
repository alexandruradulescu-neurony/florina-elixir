defmodule Florina.Workers.ExtractDocumentText do
  @moduledoc """
  Turns an uploaded client document into plain text so Florina can read it.

  Runs per document after upload. Text/CSV files are read directly, Word `.docx`
  is unzipped and stripped to text, and PDFs are read by Claude itself (native
  document input — no extra software on the server). The result is stored on the
  document row (`extracted_text` + `extraction_status`), which the call-prep
  assembler then feeds into the prompt as fenced, untrusted data.

  Args: `tenant_slug`, `document_id`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Florina.{Clients, Storage, Tenants}
  alias Florina.Workers.Tenant

  @extract_system "You extract text from documents. Return ONLY the document's " <>
                    "text content verbatim — no commentary, no headers, no markdown fences."

  # Keep stored text bounded (the prompt fence caps again at a lower limit).
  @max_stored_text 100_000

  # Anthropic caps a request at ~32MB; base64 inflates ~33%, so skip PDFs whose
  # encoded size would exceed this rather than send a request that will be rejected.
  @pdf_base64_limit 30_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug, "document_id" => doc_id}} = job) do
    case Tenant.pin_active(slug) do
      :skip ->
        Logger.info("[ExtractDocumentText] tenant=#{slug} not active — skipping")
        :ok

      :ok ->
        do_extract(Tenants.get_by_slug(slug), doc_id, job)
    end
  end

  defp do_extract(nil, _doc_id, _job), do: :ok

  defp do_extract(tenant, doc_id, job) do
    case Clients.get_document(doc_id) do
      nil ->
        # Deleted between enqueue and run — nothing to extract.
        :ok

      doc ->
        path = Storage.file_path(tenant.id, doc.client_id, doc.stored_filename)

        case extract(path, doc.original_filename) do
          {:ok, status, text} ->
            Clients.update_document(doc, %{extraction_status: status, extracted_text: cap(text)})
            :ok

          # Transient failure (API overload / network). Let Oban retry rather than
          # marking the document permanently unreadable — but on the final attempt
          # persist :failed so it doesn't stay :pending forever.
          {:retry, reason} ->
            if final_attempt?(job) do
              Logger.warning(
                "[ExtractDocumentText] giving up on doc=#{doc_id} after #{job.attempt} attempts: #{inspect(reason)}"
              )

              Clients.update_document(doc, %{extraction_status: :failed})
              :ok
            else
              Logger.warning(
                "[ExtractDocumentText] transient error on doc=#{doc_id} (attempt #{job.attempt}/#{job.max_attempts}), retrying: #{inspect(reason)}"
              )

              {:error, reason}
            end
        end
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  # --- Extraction dispatch ---------------------------------------------------
  # Returns `{:ok, status, text}` for a terminal outcome (:done | :failed |
  # :unsupported) or `{:retry, reason}` for a transient failure worth retrying.

  defp extract(path, filename) do
    extract_by_type(path, filename)
  rescue
    e ->
      # A raised exception here is a deterministic problem with the file itself
      # (unreadable, corrupt zip), not a transient one — mark it failed.
      Logger.warning("[ExtractDocumentText] failed for #{filename}: #{Exception.message(e)}")
      {:ok, :failed, nil}
  end

  defp extract_by_type(path, filename) do
    case filename |> Path.extname() |> String.downcase() do
      ext when ext in [".txt", ".md", ".csv"] -> extract_text_file(path)
      ".docx" -> extract_docx(path)
      ".pdf" -> extract_pdf(path)
      _ -> {:ok, :unsupported, nil}
    end
  end

  defp extract_text_file(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, :done, ensure_utf8(bin)}
      {:error, _} -> {:ok, :failed, nil}
    end
  end

  # `.docx` is a zip; the body text lives in `word/document.xml`. Pull just that
  # entry into memory (built-in `:zip`, no dependency) and strip the XML to text.
  defp extract_docx(path) do
    case :zip.unzip(String.to_charlist(path), [:memory, {:file_list, [~c"word/document.xml"]}]) do
      {:ok, [{_name, xml} | _]} -> {:ok, :done, docx_xml_to_text(xml)}
      _ -> {:ok, :failed, nil}
    end
  end

  defp docx_xml_to_text(xml) do
    xml
    |> to_string()
    |> String.replace(~r{</w:p>}, "\n")
    |> String.replace(~r{<w:tab\s*/?>}, "\t")
    |> String.replace(~r{<[^>]+>}, "")
    |> decode_xml_entities()
    |> String.trim()
  end

  defp decode_xml_entities(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # Claude reads the PDF natively via a document content block; no local PDF parser.
  defp extract_pdf(path) do
    data = path |> File.read!() |> Base.encode64()

    if byte_size(data) > @pdf_base64_limit do
      {:ok, :unsupported, nil}
    else
      messages = [
        %{
          role: "user",
          content: [
            %{
              type: "document",
              source: %{type: "base64", media_type: "application/pdf", data: data}
            },
            %{type: "text", text: "Extract all readable text from this document."}
          ]
        }
      ]

      client = Application.get_env(:florina, :anthropic_client, Florina.Anthropic)

      case client.complete(messages, system: @extract_system, max_tokens: 8192) do
        {:ok, %{text: text} = result} when is_binary(text) ->
          {:ok, :done, mark_truncation(text, Map.get(result, :stop_reason))}

        {:error, reason} ->
          if transient?(reason), do: {:retry, reason}, else: {:ok, :failed, nil}

        _ ->
          {:ok, :failed, nil}
      end
    end
  end

  # A document longer than the extraction token cap comes back cut mid-text with
  # stop_reason "max_tokens" — flag it so call-prep doesn't quote it as complete.
  defp mark_truncation(text, "max_tokens"),
    do: text <> "\n\n…[extraction truncated: document exceeded the extraction size limit]"

  defp mark_truncation(text, _stop_reason), do: text

  # Retry API overloads / rate limits / 5xx / network errors; treat everything
  # else (bad request, missing config) as a permanent failure.
  defp transient?({:http, status, _body}),
    do: status in [408, 409, 425, 429, 500, 502, 503, 504, 529]

  defp transient?(:timeout), do: true
  defp transient?(reason) when is_exception(reason), do: true
  defp transient?(_reason), do: false

  # --- Helpers ---------------------------------------------------------------

  defp cap(text) when is_binary(text), do: String.slice(text, 0, @max_stored_text)
  defp cap(_), do: nil

  # Keep only valid UTF-8 codepoints so a mislabelled/binary "text" file can't
  # store invalid bytes that would later break the prompt or the DB write.
  defp ensure_utf8(bin) do
    if String.valid?(bin), do: bin, else: for(<<c::utf8 <- bin>>, into: "", do: <<c::utf8>>)
  end
end
