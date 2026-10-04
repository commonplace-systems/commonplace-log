defmodule Commonplace.Log.LocalSidecar do
  @moduledoc """
  The local checkpoint SIDECAR file beside a log's database
  (CHECKPOINT-SNAP-1, Phase B round 3): `<data_dir>/<log_id>.checkpoint`.

  The log does not interpret its bytes. It is local, disposable, derived state
  owned by the log's consumer (commonplace-doc's DocHost writes a checkpoint
  there). This module only gives it a safe file discipline:

    * **mode 600** -- created owner-only before any byte is written, and a
      read REFUSES a file with any group/other permission bit
      (`:insecure_mode`): a cache others could write is not this host's cache;
    * **atomic replace** -- written to a unique temporary file in an
      owner-only (0700) subdirectory of the same directory, fsynced, then
      renamed over the old one, so a crash leaves the old file or the new one,
      never a torn one (`clear/1` removes leftover temporaries);
    * **bounded read** -- opened, then at most the caller's bound plus one
      byte read (`:too_large` beyond it); a symlink is refused;
    * **never imported** -- `Commonplace.LogStore.SQLite.restore_log/3` clears
      it before a restore writes the target, and a restored or re-created log
      has a new incarnation (`Commonplace.Log.LocalFrontier`), so a sidecar
      from any other incarnation is refused by its consumer regardless.

  Nothing here makes the bytes trustworthy: the consumer keys and verifies
  them and discards anything it cannot verify.
  """

  import Bitwise

  @suffix ".checkpoint"

  @doc "The sidecar path for `log_id` in `data_dir`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(data_dir, log_id), do: Path.join(data_dir, log_id <> @suffix)

  @tmp_dir ".checkpoint-tmp"

  @doc """
  Reads the sidecar: `{:ok, bytes}`, `{:error, :missing}`, or a refusal. The
  path must be a regular file (a SYMLINK is refused, `:not_regular_file`)
  with no group/other permission bit (`:insecure_mode`). It is opened, the
  opened file is checked to be the one inspected (same device and inode, or
  `:changed`), and at most `max_bytes + 1` bytes are read (`:too_large`).
  """
  @spec read(Path.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read(path, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, info} <- inspect_path(path),
         {:ok, io} <- open_read(path) do
      try do
        with {:ok, opened} <- fstat(io),
             :ok <- if(same_file?(info, opened), do: :ok, else: {:error, :changed}) do
          bounded_read(io, max_bytes)
        end
      after
        :file.close(io)
      end
    end
  end

  defp inspect_path(path) do
    case :file.read_link_info(path, [:raw]) do
      {:ok, {:file_info, _size, :regular, _access, _at, _mt, _ct, mode, _links, dev, _minor, inode, _uid, _gid} = info} ->
        if (mode &&& 0o077) != 0, do: {:error, :insecure_mode}, else: {:ok, {dev, inode, info}}

      {:ok, _not_regular} ->
        {:error, :not_regular_file}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp open_read(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp fstat(io) do
    case :file.read_file_info(io, [:raw]) do
      {:ok, {:file_info, _size, type, _access, _at, _mt, _ct, _mode, _links, dev, _minor, inode, _uid, _gid}} ->
        {:ok, {type, dev, inode}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp same_file?({dev, inode, _info}, {:regular, dev, inode}), do: true
  defp same_file?(_inspected, _opened), do: false

  defp bounded_read(io, max_bytes) do
    case :file.read(io, max_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :too_large}
      :eof -> {:ok, <<>>}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Atomically replaces the sidecar with `bytes` (mode 600). The temporary file
  is created inside `<dir>/#{@tmp_dir}/`, a directory that is mode 0700
  before any file is created in it, so the bytes are never readable by
  anyone else, not even before the file's own chmod; it is fsynced, then
  renamed over the sidecar. `:ok` or `{:error, {:write_failed, reason}}`; on
  error the previous file is intact and the temporary file is removed.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, bytes) do
    tmp = Path.join(tmp_dir(path), "#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    result =
      with :ok <- ensure_tmp_dir(tmp_dir(path)),
           {:ok, io} <- :file.open(tmp, [:write, :binary, :exclusive, :raw]),
           :ok <- close_on_error(io, File.chmod(tmp, 0o600)),
           :ok <- close_on_error(io, :file.write(io, bytes)),
           :ok <- close_on_error(io, :file.sync(io)),
           :ok <- :file.close(io) do
        :file.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end

  defp tmp_dir(path), do: Path.join(Path.dirname(path), @tmp_dir)

  # The directory must be a real directory owned-only (0700); one that exists
  # with any other mode, or as a symlink, is refused rather than repaired.
  defp ensure_tmp_dir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
    |> case do
      :ok ->
        case :file.read_link_info(dir, [:raw]) do
          {:ok, {:file_info, _, :directory, _, _, _, _, mode, _, _, _, _, _, _}} when (mode &&& 0o777) == 0o700 -> :ok
          {:ok, _} -> {:error, :insecure_tmp_dir}
          {:error, reason} -> {:error, reason}
        end

      error ->
        error
    end
  end

  defp close_on_error(_io, :ok), do: :ok

  defp close_on_error(io, {:error, _} = error) do
    _ = :file.close(io)
    error
  end

  @doc """
  Removes the sidecar if present, and any leftover temporary files of this
  sidecar (from a write a crash interrupted). `:ok` when absent.
  """
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(path) do
    Path.wildcard(Path.join(tmp_dir(path), Path.basename(path) <> ".tmp-*"))
    |> Enum.each(&File.rm/1)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:clear_failed, reason}}
    end
  end
end
