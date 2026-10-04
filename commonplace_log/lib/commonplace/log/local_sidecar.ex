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
    * **atomic replace** -- written to a unique temporary file in the same
      directory, fsynced, then renamed over the old one, so a crash leaves the
      old file or the new one, never a torn one;
    * **bounded read** -- a file larger than the caller's bound is refused
      (`:too_large`) without being read;
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

  @doc "Reads the sidecar: `{:ok, bytes}`, `{:error, :missing}`, or another refusal."
  @spec read(Path.t(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def read(path, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} ->
        cond do
          (mode &&& 0o077) != 0 -> {:error, :insecure_mode}
          size > max_bytes -> {:error, :too_large}
          true -> read_bounded(path, max_bytes)
        end

      {:ok, %File.Stat{}} ->
        {:error, :not_regular_file}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp read_bounded(path, max_bytes) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :too_large}
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Atomically replaces the sidecar with `bytes` (mode 600). `:ok` or
  `{:error, {:write_failed, reason}}`; on error the previous file is intact
  and the temporary file is removed.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()}
  def write(path, bytes) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    result =
      with {:ok, io} <- :file.open(tmp, [:write, :binary, :exclusive, :raw]),
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

  defp close_on_error(_io, :ok), do: :ok

  defp close_on_error(io, {:error, _} = error) do
    _ = :file.close(io)
    error
  end

  @doc "Removes the sidecar if present. `:ok` when absent."
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:clear_failed, reason}}
    end
  end
end
