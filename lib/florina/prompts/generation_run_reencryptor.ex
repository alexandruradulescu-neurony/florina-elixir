defmodule Florina.Prompts.GenerationRunReencryptor do
  @moduledoc """
  Repairs `voice_generationrun` rows corrupted by the original
  `EncryptSensitiveFields` migration, which converted the PII columns to `bytea`
  with a raw `text::bytea` cast instead of Cloak ciphertext.

  The raw cast left exactly the plaintext bytes Cloak itself encrypts (the string
  for Binary fields, the JSON text for Map fields), so `Vault.encrypt(raw)` yields
  the correct ciphertext for both. Each value is probed with a Cloak decrypt;
  values that already decrypt are left untouched, the rest are re-encrypted.
  Idempotent, and a no-op on an empty table.

  Invoked from the `ReencryptGenerationrunPlaintext` tenant migration. Kept in
  `lib/` (not inline in the migration) so it is compiled and unit-testable.
  """

  @columns ~w(claude_request claude_response error context_bundle parsed_outputs)

  @doc """
  Re-encrypt corrupted rows in the given (already pinned) tenant repo module.
  Returns `:ok`.
  """
  def run(repo) do
    ensure_vault_started()

    cols = Enum.join(@columns, ", ")
    %{rows: rows} = repo.query!("SELECT id, #{cols} FROM voice_generationrun")

    Enum.each(rows, fn [id | values] -> repair_row(repo, id, values) end)
  end

  defp repair_row(repo, id, values) do
    fixes =
      @columns
      |> Enum.zip(values)
      |> Enum.reject(fn {_col, raw} -> is_nil(raw) or already_encrypted?(raw) end)
      |> Enum.map(fn {col, raw} -> {col, encrypt!(raw)} end)

    unless fixes == [] do
      assigns =
        fixes
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {{col, _v}, i} -> "#{col} = $#{i}" end)

      params = Enum.map(fixes, fn {_c, v} -> v end)

      repo.query!(
        "UPDATE voice_generationrun SET #{assigns} WHERE id = $#{length(params) + 1}",
        params ++ [id]
      )
    end
  end

  defp already_encrypted?(raw) do
    match?({:ok, _}, Florina.Vault.decrypt(raw))
  rescue
    _ -> false
  end

  defp encrypt!(raw) do
    {:ok, ciphertext} = Florina.Vault.encrypt(raw)
    ciphertext
  end

  defp ensure_vault_started do
    case Process.whereis(Florina.Vault) do
      nil -> {:ok, _} = Florina.Vault.start_link([])
      _pid -> :ok
    end
  end
end
