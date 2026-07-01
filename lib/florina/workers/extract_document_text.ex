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
  def perform(%Oban.Job{args: %{"tenant_slug" => slug, "document_id" => doc_id}}) do
    case Tenant.pin_active(slug) do
      :skip ->
        Logger.info("[ExtractDocumentText] tenant=#{slug} not active — skipping")
        :ok

      :ok ->
        do_extract(Tenants.get_by_slug(slug), doc_id)
    end
  end

  defp do_extract(nil, _doc_id), do: :ok

  defp do_extract(tenant, doc_id) do
    case Clients.get_document(doc_id) do
      nil ->
        # Deleted between enqueue and run — nothing to extract.
        :ok

      doc ->
        path = Storage.file_path(tenant.id, doc.client_id, doc.stored_filename)
        {status, text} = extract(path, doc.original_filename)
        Clients.update_document(doc, %{extraction_status: status, extracted_text: cap(text)})
        :ok
    end
  end

  # --- Extraction dispatch ---------------------------------------------------

  defp extract(path, filename) do
    extract_by_type(path, filename)
  rescue
    e ->
      Logger.warning("[ExtractDocumentText] failed for #{filename}: #{Exception.message(e)}")
      {:failed, nil}
  end

  defp extract_by_type(path, filename) do
    case filename |> Path.extname() |> String.downcase() do
      ext when ext in [".txt", ".md", ".csv"] -> extract_text_file(path)
      ".docx" -> extract_docx(path)
      ".pdf" -> extract_pdf(path)
      _ -> {:unsupported, nil}
    end
  end

  defp extract_text_file(path) do
    case File.read(path) do
      {:ok, bin} -> {:done, ensure_utf8(bin)}
      {:error, _} -> {:failed, nil}
    end
  end

  # `.docx` is a zip; the body text lives in `word/document.xml`. Pull just that
  # entry into memory (built-in `:zip`, no dependency) and strip the XML to text.
  defp extract_docx(path) do
    case :zip.unzip(String.to_charlist(path), [:memory, {:file_list, [~c"word/document.xml"]}]) do
      {:ok, [{_name, xml} | _]} -> {:done, docx_xml_to_text(xml)}
      _ -> {:failed, nil}
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
      {:unsupported, nil}
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
        {:ok, %{text: text}} when is_binary(text) -> {:done, text}
        _ -> {:failed, nil}
      end
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp cap(text) when is_binary(text), do: String.slice(text, 0, @max_stored_text)
  defp cap(_), do: nil

  # Keep only valid UTF-8 codepoints so a mislabelled/binary "text" file can't
  # store invalid bytes that would later break the prompt or the DB write.
  defp ensure_utf8(bin) do
    if String.valid?(bin), do: bin, else: for(<<c::utf8 <- bin>>, into: "", do: <<c::utf8>>)
  end
end
