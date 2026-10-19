defmodule Gitastic.Checks do
  @moduledoc """
  Runs the repo's checks on the tip of local `main` before it may be pushed:
  the command from `gitastic serve --check CMD` (`sh -c`), in a checkout of its
  own (a detached git worktree under `~/.gitastic/checks/`), one run at a time.
  `want/2` asks for a commit; while a run goes, only the newest commit asked
  for waits behind it, so a superseded tip is skipped.

  A result per commit (`%{sha, ok, started_at, finished_at, log}`, the log's
  last lines) is kept on disk with the whole log beside it, and broadcast on
  `topic/0` as `{:checks, sha}`. Without a command there are no checks, and
  Push is not held back.
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
  def log(sha, server \\ __MODULE__), do: GenServer.call(server, {:log, sha})

  ## Server

  @impl true
  def init(opts) do
    state = %{
      command: Keyword.get(opts, :command, Application.get_env(:gitastic, :check_command)),
      dir: Keyword.get(opts, :dir, Path.join([System.user_home!(), ".gitastic", "checks"])),
      store: Keyword.get(opts, :store, "checks"),
      results: load(Keyword.get(opts, :store, "checks")),
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
        state.running && state.running.sha == sha -> {:running, state.running.started_at}
        state.next && elem(state.next, 1) == sha -> {:queued, nil}
        true -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:log, sha}, _from, state) do
    log =
      if state.running && state.running.sha == sha,
        do: IO.iodata_to_binary(Enum.reverse(state.running.log)),
        else: read_log(state, sha)

    {:reply, log, state}
  end

  @impl true
  def handle_cast({:want, _repo, _sha}, %{command: nil} = state), do: {:noreply, state}

  def handle_cast({:want, repo, sha}, state) do
    cond do
      Map.has_key?(state.results, sha) -> {:noreply, state}
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

  def handle_info({:timeout, sha}, %{running: %{sha: sha, port: port}} = state) do
    Port.close(port)
    state = update_in(state.running.log, &["\n[gitastic] Stopped after 30 minutes.\n" | &1])
    {:noreply, finish(state, false)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Running

  defp start(state, repo, sha) do
    started_at = DateTime.utc_now()
    broadcast(sha)

    case checkout(state, repo, sha) do
      {:ok, dir} ->
        port =
          Port.open({:spawn_executable, System.find_executable("sh")}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-c", state.command],
            cd: dir
          ])

        timer = Process.send_after(self(), {:timeout, sha}, @timeout_ms)
        Gitastic.Events.emit("checks-running", "main", Gitastic.Events.short(sha))
        run = %{sha: sha, port: port, started_at: started_at, log: [], timer: timer}
        %{state | running: run}

      {:error, output} ->
        run = %{sha: sha, port: nil, started_at: started_at, timer: nil, log: [output]}
        finish(%{state | running: run}, false)
    end
  end

  defp finish(%{running: run} = state, ok?) do
    if run.timer, do: Process.cancel_timer(run.timer)
    log = IO.iodata_to_binary(Enum.reverse(run.log))
    write_log(state, run.sha, log)

    result = %{
      sha: run.sha,
      ok: ok?,
      started_at: run.started_at,
      finished_at: DateTime.utc_now(),
      log: log |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n")
    }

    results =
      state.results
      |> Map.put(run.sha, result)
      |> Enum.sort_by(fn {_, r} -> r.finished_at end, {:desc, DateTime})
      |> Enum.take(@keep)
      |> Map.new()

    if state.store, do: Gitastic.Store.put_named(state.store, results)
    broadcast(run.sha)

    seconds = DateTime.diff(result.finished_at, run.started_at)
    event = if ok?, do: "checks-passed", else: "checks-failed"
    Gitastic.Events.emit(event, "main", "#{Gitastic.Events.short(run.sha)} in #{seconds}s")
    state = %{state | results: results, running: nil}

    case state.next do
      {repo, sha} -> start(%{state | next: nil}, repo, sha)
      nil -> state
    end
  end

  # A detached worktree of the repo, moved to `sha`; untracked files go, but
  # ignored ones (deps, _build) stay so the next run is quick.
  defp checkout(state, repo, sha) do
    dir =
      Path.join(
        state.dir,
        repo |> Path.expand() |> Path.basename() |> String.trim_trailing(".git")
      )

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

  defp broadcast(sha), do: Phoenix.PubSub.broadcast(Gitastic.PubSub, topic(), {:checks, sha})

  defp load(nil), do: %{}
  defp load(store), do: Gitastic.Store.get_named(store) || %{}

  defp log_file(state, sha), do: Path.join([state.dir, "logs", sha <> ".log"])

  defp write_log(state, sha, log) do
    file = log_file(state, sha)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, log)
  end

  defp read_log(state, sha) do
    case File.read(log_file(state, sha)) do
      {:ok, log} -> log
      {:error, _} -> nil
    end
  end
end
