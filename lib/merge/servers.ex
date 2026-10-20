defmodule Merge.Servers do
  @moduledoc """
  The worktrees of each repo the merge requests use, and the dev server running
  in each: a process listening on a TCP port from inside the tree. Read-only:
  merge starts and stops nothing here. `Merge.Watcher` reads it every
  round and broadcasts it on `topic/0` as `{:servers, repos}`; `read/0` reads
  it at once.

  A tree's URL is its `.dev-url` file (the app's own dev tunnel writes it when
  the server starts), else the server's localhost port. Neither shows while
  nothing listens: a tunnel to a dead server is a 502.
  """

  alias Merge.{Drift, Git, MergeRequest}

  def topic, do: "servers"

  @doc """
  One entry per repo, `%{name, dir, trees}`, each tree `%{path, name, branch,
  head, ports, pid, url}`: `ports` empty and `url` nil when no server listens
  from it. main's tree comes first. A detached tree (merge's own checks
  checkout, say) is listed only while a server runs in it. `listeners` is
  `listeners/0`'s map.
  """
  def read(repos \\ repos(), listeners \\ listeners()) do
    repos
    |> Enum.map(&Git.common_dir/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&repo(&1, listeners))
    |> Enum.reject(&(&1.trees == []))
  end

  @doc "The repos to read: `serve --repo`'s and every merge request's."
  def repos do
    [Drift.repo() | Enum.map(MergeRequest.list(), &MergeRequest.git_repo/1)]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  A merge request's tree: the one its branch is checked out in, else the one it
  was opened in; nil when neither is there any more.
  """
  def tree_for(mr, repos) do
    trees = Enum.flat_map(repos, & &1.trees)
    Enum.find(trees, &(&1.branch == mr.branch)) || Enum.find(trees, &(&1.path == mr.repo))
  end

  @doc "What the watcher read last, or nil before its first round."
  def current, do: :persistent_term.get({__MODULE__, :current}, nil)

  @doc "Reads, keeps the result as current, and broadcasts it."
  def refresh do
    repos = read()
    :persistent_term.put({__MODULE__, :current}, repos)
    Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:servers, repos})
    repos
  end

  @doc """
  Listening TCP ports by the working directory of the process behind each,
  `%{cwd => [%{port, pid}]}`, from `ss -ltnp` and `/proc`. A map in
  `config :merge, :listeners` stands in for it (tests).
  """
  def listeners do
    Application.get_env(:merge, :listeners) || parse_listeners(ss())
  end

  @doc false
  def parse_listeners(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&listener/1)
    |> Enum.uniq_by(&{&1.pid, &1.port})
    |> Enum.group_by(& &1.cwd, &Map.delete(&1, :cwd))
  end

  # LISTEN 0 1024 127.0.0.1:33997 0.0.0.0:* users:(("beam.smp",pid=2494745,fd=33))
  # One process listening on v4 and v6 gives two lines; a socket without a
  # visible process (another user's) has no users: part.
  defp listener(line) do
    with [_state, _recv, _send, local | _] <- String.split(line),
         {port, ""} <- local |> String.split(":") |> List.last() |> Integer.parse(),
         [_, pid] <- Regex.run(~r/pid=(\d+)/, line),
         {:ok, cwd} <- File.read_link("/proc/#{pid}/cwd") do
      [%{cwd: cwd, port: port, pid: String.to_integer(pid)}]
    else
      _ -> []
    end
  end

  defp ss do
    case System.cmd("ss", ["-ltnpH"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  rescue
    ErlangError -> ""
  end

  defp repo(dir, listeners) do
    worktrees = Git.worktrees(dir)
    paths = Enum.map(worktrees, & &1.path)

    trees =
      worktrees
      |> Enum.map(&tree(&1, paths, listeners))
      |> Enum.reject(&(&1.branch == nil and &1.ports == []))
      |> Enum.sort_by(&{&1.branch != "main", &1.name})

    %{name: name(dir), dir: dir, trees: trees}
  end

  # A server belongs to the tree it runs in, or the innermost one when trees nest.
  defp tree(%{path: path} = t, paths, listeners) do
    servers =
      listeners
      |> Enum.filter(fn {cwd, _} -> owner(paths, cwd) == path end)
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.sort_by(& &1.port)

    ports = Enum.map(servers, & &1.port)
    first = List.first(servers)

    %{
      path: path,
      name: Path.basename(path),
      branch: t.branch,
      head: t.head,
      ports: ports,
      pid: first && first.pid,
      url: url(path, ports)
    }
  end

  defp owner(paths, cwd) do
    paths
    |> Enum.filter(&(cwd == &1 or String.starts_with?(cwd, &1 <> "/")))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp url(_path, []), do: nil

  defp url(path, [port | _]) do
    case File.read(Path.join(path, ".dev-url")) do
      {:ok, url} ->
        case String.trim(url) do
          "" -> "http://localhost:#{port}"
          url -> url
        end

      _ ->
        "http://localhost:#{port}"
    end
  end

  # /root/projects/dayofplenty (bare) → dayofplenty; /root/projects/merge/.git → merge
  defp name(dir) do
    case Path.basename(dir) do
      ".git" -> dir |> Path.dirname() |> Path.basename()
      base -> String.replace_suffix(base, ".git", "")
    end
  end
end
