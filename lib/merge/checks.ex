defmodule Merge.Checks do
  @moduledoc """
  Runs the repo's checks on the tip of local `main` before it may be pushed:
  the command from `merge serve --check CMD` (`sh -c`), in a checkout of its
  own (a detached git worktree under `~/.merge/checks/`), one run at a time.
  `want/2` asks for a commit; while a run goes, only the newest commit asked
  for waits behind it, so a superseded tip is skipped.

  A result per commit (`%{sha, ok, started_at, finished_at, log}`, the log's
  last lines) is kept on disk with the whole log beside it, and broadcast on
  `topic/0` as `{:checks, sha}`. Without a command there are no checks, and
  Push is not held back.

  The image check (`merge serve --check-image CMD`) mirrors GitHub's Docker
  workflow: it runs after the first on the same commit, in the same checkout,
  under `nice`, and only when the commit changes a path that workflow watches
  (`Merge.ImagePaths`); else it is `:not_needed`. When a newer tip is waiting
  by the time the first check ends, the old tip's image check is skipped.
  Its results and logs are kept beside the first's.
  """

  use GenServer

  @keep 30
  @tail_lines 80
  @timeout_ms 30 * 60_000

  def topic, do: "checks"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "True when a check command is configured."
  def enabled?(server \\ __MODULE__), do: GenServer.call(server, :enabled?)

  @doc "Asks for `sha` of `repo` to be checked, unless it has been or is being."
  def want(repo, sha, server \\ __MODULE__), do: GenServer.cast(server, {:want, repo, sha})

  @doc "`:none`, `{:running, started_at}`, `{:queued, nil}` or the result for `sha`."
  def status(sha, server \\ __MODULE__), do: GenServer.call(server, {:status, sha})

  @doc """
  The image check of `sha`: `:off` without an image command, `:not_needed`,
  `:none`, `{:running, started_at}`, `{:queued, nil}` or its result.
  """
  def image_status(sha, server \\ __MODULE__), do: GenServer.call(server, {:image_status, sha})

  @doc """
  The check that speaks for a merged merge request, as `{sha, status}`: its
  merge commit's own result; else, while it isn't pushed yet, the check of
  main's tip (`main`), which contains it. nil when there's neither, or no checks.
  """
  def for_merge_request(mr, main, server \\ __MODULE__)

  def for_merge_request(%{merged: %{sha: sha} = merged}, main, server) do
    if Process.whereis(server) && enabled?(server) do
      case status(sha, server) do
        %{} = result -> {sha, result}
        _ when not merged.pushed and is_binary(main) -> {main, status(main, server)}
        _ -> nil
      end
    end
  end

  def for_merge_request(_mr, _main, _server), do: nil

  @doc "The whole log of `sha`'s run so far, or nil."
  def log(sha, server \\ __MODULE__), do: GenServer.call(server, {:log, :check, sha})

  @doc "The whole log of `sha`'s image check so far, or nil."
  def image_log(sha, server \\ __MODULE__), do: GenServer.call(server, {:log, :image, sha})

  ## Server

  @impl true
  def init(opts) do
    state = %{
      command: Keyword.get(opts, :command, Application.get_env(:merge, :check_command)),
      image_command:
        Keyword.get(opts, :image_command, Application.get_env(:merge, :check_image_command)),
      dir:
        Keyword.get_lazy(opts, :dir, fn ->
          Application.get_env(:merge, :checks_dir) ||
            Path.join([System.user_home!(), ".merge", "checks"])
        end),
      store: Keyword.get(opts, :store, "checks"),
      results: load(Keyword.get(opts, :store, "checks")),
      image_results: load(store_name(Keyword.get(opts, :store, "checks"), :image)),
      # Whether a commit needs the image check, decided when it is wanted.
      image_needed: %{},
      running: nil,
      next: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:enabled?, _from, state), do: {:reply, state.command != nil, state}

  def handle_call({:status, sha}, _from, state) do
    reply =
      cond do
        result = state.results[sha] -> result
        running?(state, :check, sha) -> {:running, state.running.started_at}
        state.next && elem(state.next, 1) == sha -> {:queued, nil}
        true -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:image_status, sha}, _from, state) do
    reply =
      cond do
        state.image_command == nil -> :off
        result = state.image_results[sha] -> result
        running?(state, :image, sha) -> {:running, state.running.started_at}
        state.image_needed[sha] == false -> :not_needed
        state.image_needed[sha] && waiting?(state, sha) -> {:queued, nil}
        true -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:log, kind, sha}, _from, state) do
    log =
      if running?(state, kind, sha),
        do: IO.iodata_to_binary(Enum.reverse(state.running.log)),
        else: read_log(state, kind, sha)

    {:reply, log, state}
  end

  @impl true
  def handle_cast({:want, _repo, _sha}, %{command: nil} = state), do: {:noreply, state}

  def handle_cast({:want, repo, sha}, state) do
    state = decide_image(state, repo, sha)

    cond do
      todo(state, sha) == nil -> {:noreply, state}
      state.running && state.running.sha == sha -> {:noreply, state}
      state.running -> {:noreply, %{state | next: {repo, sha}}}
      true -> {:noreply, start(state, repo, sha)}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{running: %{port: port} = run} = state) do
    {:noreply, %{state | running: %{run | log: [data | run.log]}}}
  end

  def handle_info({port, {:exit_status, status}}, %{running: %{port: port}} = state) do
    {:noreply, finish(state, status == 0)}
  end

  def handle_info({:timeout, kind, sha}, %{running: %{kind: kind, sha: sha, port: port}} = state) do
    Port.close(port)
    state = update_in(state.running.log, &["\n[merge] Stopped after 30 minutes.\n" | &1])
    {:noreply, finish(state, false)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp running?(state, kind, sha),
    do: match?(%{kind: ^kind, sha: ^sha}, state.running)

  defp waiting?(state, sha),
    do: running?(state, :check, sha) or match?({_, ^sha}, state.next)

  # Decided once per commit, against origin/main as it is when the commit is wanted.
  defp decide_image(%{image_command: nil} = state, _repo, _sha), do: state

  defp decide_image(state, repo, sha) do
    if Map.has_key?(state.image_needed, sha) or Map.has_key?(state.image_results, sha) do
      state
    else
      needed = Merge.ImagePaths.needed?(repo, sha)
      needs = state.image_needed |> Map.put(sha, needed) |> Enum.take(-@keep) |> Map.new()
      %{state | image_needed: needs}
    end
  end

  # What is left to run on `sha`: :check, :image, or nil.
  defp todo(state, sha) do
    cond do
      not Map.has_key?(state.results, sha) -> :check
      state.image_needed[sha] && not Map.has_key?(state.image_results, sha) -> :image
      true -> nil
    end
  end

  ## Running

  defp start(state, repo, sha) do
    case todo(state, sha) do
      nil -> state
      kind -> start(state, kind, repo, sha)
    end
  end

  defp start(state, kind, repo, sha) do
    started_at = DateTime.utc_now()

    case checkout(state, repo, sha) do
      {:ok, dir} ->
        port =
          Port.open({:spawn_executable, executable(kind)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args(state, kind),
            cd: dir
          ])

        timer = Process.send_after(self(), {:timeout, kind, sha}, @timeout_ms)
        Merge.Events.emit(event(kind, "running"), "main", Merge.Events.short(sha))

        run = %{
          kind: kind,
          repo: repo,
          sha: sha,
          port: port,
          started_at: started_at,
          log: [],
          timer: timer
        }

        broadcast(sha)
        %{state | running: run}

      {:error, output} ->
        run = %{
          kind: kind,
          repo: repo,
          sha: sha,
          port: nil,
          started_at: started_at,
          timer: nil,
          log: [output]
        }

        finish(%{state | running: run}, false)
    end
  end

  # The image check goes at the lowest priority: this machine clamps its CPU under load.
  defp executable(:check), do: System.find_executable("sh")
  defp executable(:image), do: System.find_executable("nice") || System.find_executable("sh")

  defp args(state, :check), do: ["-c", state.command]

  defp args(state, :image) do
    if System.find_executable("nice"),
      do: ["-n", "19", "sh", "-c", state.image_command],
      else: ["-c", state.image_command]
  end

  defp event(:check, what), do: "checks-" <> what
  defp event(:image, what), do: "image-" <> what

  defp finish(%{running: run} = state, ok?) do
    if run.timer, do: Process.cancel_timer(run.timer)
    log = IO.iodata_to_binary(Enum.reverse(run.log))
    write_log(state, run.kind, run.sha, log)

    result = %{
      sha: run.sha,
      ok: ok?,
      started_at: run.started_at,
      finished_at: DateTime.utc_now(),
      log: log |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n")
    }

    key = if run.kind == :check, do: :results, else: :image_results

    results =
      state
      |> Map.fetch!(key)
      |> Map.put(run.sha, result)
      |> Enum.sort_by(fn {_, r} -> r.finished_at end, {:desc, DateTime})
      |> Enum.take(@keep)
      |> Map.new()

    if state.store, do: Merge.Store.put_named(store_name(state.store, run.kind), results)

    seconds = DateTime.diff(result.finished_at, run.started_at)
    event = event(run.kind, if(ok?, do: "passed", else: "failed"))
    Merge.Events.emit(event, "main", "#{Merge.Events.short(run.sha)} in #{seconds}s")
    state = state |> Map.put(key, results) |> Map.put(:running, nil)
    broadcast(run.sha)

    # A newer tip waiting goes first: the image check of a superseded one is skipped.
    case state.next do
      {repo, sha} -> start(%{state | next: nil}, repo, sha)
      nil -> start(state, run.repo, run.sha)
    end
  end

  # A detached worktree of the repo, moved to `sha`; untracked files go, but
  # ignored ones (deps, _build) stay so the next run is quick.
  defp checkout_dir(state, repo) do
    Path.join(state.dir, repo |> Path.expand() |> Path.basename() |> String.trim_trailing(".git"))
  end

  defp checkout(state, repo, sha) do
    dir = checkout_dir(state, repo)

    with {:ok, _} <- ensure_worktree(repo, dir, sha),
         {:ok, _} <- git(dir, ["checkout", "--quiet", "--detach", "--force", sha]),
         {:ok, _} <- git(dir, ["clean", "-fdq"]) do
      {:ok, dir}
    end
  end

  defp ensure_worktree(repo, dir, sha) do
    if File.dir?(dir) do
      {:ok, ""}
    else
      File.mkdir_p!(Path.dirname(dir))
      git(repo, ["worktree", "add", "--detach", dir, sha])
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, "git #{Enum.join(args, " ")}: " <> out}
    end
  end

  defp broadcast(sha), do: Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:checks, sha})

  defp load(nil), do: %{}
  defp load(store), do: Merge.Store.get_named(store) || %{}

  defp store_name(nil, _kind), do: nil
  defp store_name(store, :check), do: store
  defp store_name(store, :image), do: store <> "_image"

  defp log_file(state, :check, sha), do: Path.join([state.dir, "logs", sha <> ".log"])
  defp log_file(state, :image, sha), do: Path.join([state.dir, "logs", sha <> ".image.log"])

  defp write_log(state, kind, sha, log) do
    file = log_file(state, kind, sha)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, log)
  end

  defp read_log(state, kind, sha) do
    case File.read(log_file(state, kind, sha)) do
      {:ok, log} -> log
      {:error, _} -> nil
    end
  end
end
