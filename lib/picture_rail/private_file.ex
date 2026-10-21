defmodule PictureRail.PrivateFile do
  @moduledoc """
  Writes files that hold credentials: private to their owner (mode 0600)
  from the first byte, and replaced atomically, so a reader (or a power
  cut) sees either the old contents or the new ones.
  """

  @doc """
  Replace `path` with `contents`: written to `path <> ".tmp"`, created
  empty and made 0600 before anything is written to it, synced, then
  renamed over `path`.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, contents) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- rm(tmp),
         {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- write_private(io, tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp write_private(io, tmp, contents) do
    with :ok <- File.chmod(tmp, 0o600),
         :ok <- IO.binwrite(io, contents),
         :ok <- :file.sync(io) do
      File.close(io)
    else
      error ->
        File.close(io)
        error
    end
  end

  defp rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
