defmodule Gitastic.Store do
  @moduledoc """
  Keeps each merge request's state on disk, one Erlang term file per merge
  request under `~/.gitastic/merge_requests/`, written on every change, so a
  restart of the server keeps them. The process is still where the state lives;
  this is its copy. `config :gitastic, :store_dir` moves it; nil turns it off.
  """

  def dir, do: Application.get_env(:gitastic, :store_dir)

  @doc "Writes a merge request's state (a map), replacing the file whole."
  def put(%{branch: branch} = state) do
    with dir when is_binary(dir) <- dir() do
      File.mkdir_p!(dir)
      file = path(dir, branch)
      tmp = file <> ".tmp"
      File.write!(tmp, :erlang.term_to_binary(state))
      File.rename!(tmp, file)
    end

    :ok
  end

  @doc "Forgets a merge request."
  def delete(branch) do
    with dir when is_binary(dir) <- dir(), do: File.rm(path(dir, branch))
    :ok
  end

  @doc "Every stored merge request's state."
  def all do
    case dir() && File.ls(dir()) do
      {:ok, files} ->
        for file <- files,
            Path.extname(file) == ".term",
            state = read(Path.join(dir(), file)),
            do: state

      _ ->
        []
    end
  end

  defp read(file) do
    file |> File.read!() |> :erlang.binary_to_term()
  rescue
    _ -> nil
  end

  # Branch names have slashes; the file name is the branch, encoded.
  defp path(dir, branch), do: Path.join(dir, Base.url_encode64(branch, padding: false) <> ".term")
end
