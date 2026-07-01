defmodule Florina.Storage do
  @moduledoc """
  Disk storage for client document uploads.

  Files live under `<uploads_root>/tenant_<tenant_id>/client_<client_id>/<stored_filename>`.
  The root comes from the `:uploads_root` config — the mounted `/data` volume in
  prod, a project-local `priv/uploads` folder in dev, a throwaway tmp dir in test.

  This module only moves and removes bytes; the caller owns the metadata row
  (`Florina.Clients.Document`). Stored filenames are random UUIDs with a
  whitelisted extension, so a user-supplied name can never steer the path outside
  its own client folder.
  """

  # Documents only. Kept in one place so the LiveView `accept:` list, the
  # server-side guard, and the on-disk extension all agree.
  @accepted_extensions ~w(.pdf .docx .txt .md .csv)

  @doc "The accepted upload extensions (documents only)."
  def accepted_extensions, do: @accepted_extensions

  @doc "The configured uploads root directory."
  def root, do: Application.fetch_env!(:florina, :uploads_root)

  @doc "Absolute directory that holds one client's files."
  def client_dir(tenant_id, client_id)
      when is_integer(tenant_id) and is_integer(client_id) do
    Path.join([root(), "tenant_#{tenant_id}", "client_#{client_id}"])
  end

  @doc "Absolute path to one stored file (basename-guarded against traversal)."
  def file_path(tenant_id, client_id, stored_filename) do
    Path.join(client_dir(tenant_id, client_id), Path.basename(stored_filename))
  end

  @doc """
  Copies an uploaded temp file into the client's folder under `stored_filename`,
  creating the folder if needed. Returns the destination path. Raises on I/O error
  (the caller records nothing if the bytes didn't land).
  """
  def store(tenant_id, client_id, source_path, stored_filename) do
    dir = client_dir(tenant_id, client_id)
    File.mkdir_p!(dir)
    dest = Path.join(dir, Path.basename(stored_filename))
    File.cp!(source_path, dest)
    dest
  end

  @doc "Removes one stored file. A missing file is not an error."
  def delete_file(tenant_id, client_id, stored_filename) do
    tenant_id |> file_path(client_id, stored_filename) |> File.rm()
    :ok
  end

  @doc "Recursively removes a client's whole folder (used when a client is deleted)."
  def delete_client_dir(tenant_id, client_id) do
    tenant_id |> client_dir(client_id) |> File.rm_rf()
    :ok
  end

  @doc """
  A random, collision-free, traversal-proof on-disk name that preserves the
  original file's (lower-cased, whitelisted) extension. An unrecognised extension
  is dropped rather than trusted.
  """
  def stored_filename(original_filename) do
    Ecto.UUID.generate() <> safe_extension(original_filename)
  end

  @doc "True if the (lower-cased) extension of `filename` is an accepted document type."
  def accepted?(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    ext in @accepted_extensions
  end

  defp safe_extension(name) do
    ext = name |> Path.extname() |> String.downcase()
    if ext in @accepted_extensions, do: ext, else: ""
  end
end
