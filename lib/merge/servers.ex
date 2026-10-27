defmodule Merge.Servers do
  @moduledoc """
  The worktrees of each repo the merge requests use, and the dev server running
  in each: a process listening on a TCP port from inside the tree, and whether
  it answers. Read-only: the tree's own `bin/dev` starts and stops servers
  (`Merge.DevScript`). `Merge.Watcher` reads it every round and broadcasts it
  on `topic/0` as `{:servers, repos}`; `read/0` reads it at once.

  A tree's URL is its `.dev-url` file (the app's own dev tunnel writes it when
  the server starts), else the server's localhost port. Neither shows while
  nothing listens: a tunnel to a dead server is a 502.
  """

  alias Merge.{Drift, Git, MergeRequest}

  def topic, do: "servers"

  @doc """
  One entry per repo, `%{name, dir, trees}`, each tree `%{path, name, branch,
  head, ports, pid, url, status, reason, dev?}`: `ports` empty and `url` nil
  when no server listens from it. main's tree comes first. A detached tree
  (merge's own checks checkout, say) is listed only while a server runs in it.
  `listeners` is `listeners/0`'s map; `req` goes to the probe's `Req.get`
  (tests pass a `plug:`).

  `status` is what a GET of the tree's URL got (`probe/2`): `:up`, `:error`
  with the page's title as `reason`, `:not_answering`, or `:off` when nothing
  listens. `dev?` says the tree has an executable `bin/dev` to run.
  """
  def read(repos \\ repos(), listeners \\ listeners(), req \\ []) do
    repos
    |> Enum.map(&Git.common_dir/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&repo(&1, listeners))
    |> Enum.reject(&(&1.trees == []))
    |> probe_all(req)
  end

  @doc """
  One tree's `{status, reason}` now, as `read/3` gives it (`Merge.DevScript`
  polls it after a start or a stop).
  """
  def status(path, listeners \\ listeners(), req \\ []) do
    ports =
      listeners
      |> Enum.filter(fn {cwd, _} -> cwd == path or String.starts_with?(cwd, path <> "/") end)
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.map(& &1.port)
      |> Enum.sort()

    case url(path, ports) do
      nil -> {:off, nil}
      url -> probe(url, req)
    end
  end

  @doc """
  GETs a server's URL once, following no redirect, waiting at most 5 seconds:
  `{:up, nil}` for any answer below 500, `{:error, title}` for a 5xx (the
  page's `<title>`), `{:not_answering, "not answering"}` for a timeout, a
  refusal or a 502 (a tunnel whose server is gone).
  """
  def probe(url, req \\ []) do
    [
      url: url,
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(req)
    |> Req.get()
    |> case do
      {:ok, %{status: 502}} -> {:not_answering, "not answering"}
      {:ok, %{status: status, body: body}} when status >= 500 -> {:error, title(body, status)}
      {:ok, _} -> {:up, nil}
      {:error, _} -> {:not_answering, "not answering"}
    end
  rescue
    # Req raises when its connection pool is exhausted; that server is not
    # answering us either way, and the page must still render.
    _ -> {:not_answering, "not answering"}
  catch
    :exit, _ -> {:not_answering, "not answering"}
  end

  # Phoenix's error pages read "CompileError at GET /"; the error is the reason.
  defp title(body, status) do
    with body when is_binary(body) <- body,
         [_, title] <- Regex.run(~r{<title[^>]*>(.*?)</title>}is, body),
         title when title != "" <- title |> String.replace(~r/\s+/, " ") |> String.trim() do
      title |> String.replace(~r/ at [A-Z]+ \S*$/, "") |> unescape()
    else
      _ -> "error #{status}"
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # Every listening tree at once, so one hung server costs 5 seconds, not 5 each.
  defp probe_all(repos, req) do
    trees = repos |> Enum.flat_map(& &1.trees) |> Enum.filter(& &1.url)

    status =
      trees
      |> Task.async_stream(&probe(&1.url, req),
        timeout: 10_000,
        on_timeout: :kill_task,
        max_concurrency: 16
      )
      |> Enum.zip(trees)
      |> Map.new(fn
        {{:ok, result}, tree} -> {tree.path, result}
        {{:exit, _}, tree} -> {tree.path, {:not_answering, "not answering"}}
      end)

    Enum.map(repos, fn repo ->
      trees =
        Enum.map(repo.trees, fn tree ->
          {status, reason} = Map.get(status, tree.path, {:off, nil})
          %{tree | status: status, reason: reason}
        end)

      %{repo | trees: trees}
    end)
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

  Every `mix` command listens on a loopback port of its own for Mix's build
  sync, so a `mix test` in a tree would look like a server that doesn't answer.
  Those ports are left out: Mix names them in `port_<N>` files under
  `<tmp>/mix_pubsub_*/`, and listens with a backlog of 128. Both must match,
  since old files stay behind and a server can get a port one once named.
  """
  def listeners do
    Application.get_env(:merge, :listeners) || parse_listeners(ss(), mix_ports())
  end

  @doc false
  def parse_listeners(out, mix_ports) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&listener/1)
    |> Enum.reject(&(&1.backlog == 128 and MapSet.member?(mix_ports, &1.port)))
    |> Enum.uniq_by(&{&1.pid, &1.port})
    |> Enum.group_by(& &1.cwd, &Map.drop(&1, [:cwd, :backlog]))
  end

  # LISTEN 0 1024 127.0.0.1:33997 0.0.0.0:* users:(("beam.smp",pid=2494745,fd=33))
  # The third field of a listening socket is its backlog. One process listening
  # on v4 and v6 gives two lines; a socket without a visible process (another
  # user's) has no users: part.
  defp listener(line) do
    with [_state, _recv, backlog, local | _] <- String.split(line),
         {port, ""} <- local |> String.split(":") |> List.last() |> Integer.parse(),
         [_, pid] <- Regex.run(~r/pid=(\d+)/, line),
         {:ok, cwd} <- File.read_link("/proc/#{pid}/cwd") do
      [%{cwd: cwd, port: port, pid: String.to_integer(pid), backlog: to_int(backlog)}]
    else
      _ -> []
    end
  end

  defp to_int(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp mix_ports do
    [System.tmp_dir!(), "mix_pubsub_*", "*", "port_*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(String.replace_prefix(Path.basename(path), "port_", "")) do
        {port, ""} -> [port]
        _ -> []
      end
    end)
    |> MapSet.new()
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
      url: url(path, ports),
      status: :off,
      reason: nil,
      dev?: Merge.DevScript.script?(path)
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
