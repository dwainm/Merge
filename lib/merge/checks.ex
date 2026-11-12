defmodule Merge.Checks do
  @moduledoc """
  Runs the repo's checks on the tip of local `main` before it may be pushed:
  the command from `merge serve --check CMD` (`sh -c`), in a checkout of its
  own (a detached git worktree under `~/.merge/checks/`), one run at a time.
  `want/2` asks for a commit; while a run goes, only the newest commit asked
  for waits behind it, so a superseded tip is skipped.

  A result per commit (`%{sha, ok, started_at, finished_at, log, excerpt}`,
  the log's last lines and, when it failed, the lines of the step that failed
  first, `Merge.Checks.Excerpt`, read off the whole log) is kept on disk with the whole log beside it, and broadcast on
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
  @timeout_ms 45 * 60_000
  # A command ended by a signal: hangup, interrupt, kill, terminate (128 + its number).
  @signals [129, 130, 137, 143]
  # Cut off this many times, a commit's check is recorded as failed, so a command
  # that kills itself doesn't run for ever.
  @cut_limit 2

  def topic, do: "checks"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "True when a check command is configured."
  def enabled?(server \\ __MODULE__) do
    case Merge.Board.view({__MODULE__, server}) do
      nil -> GenServer.call(server, :enabled?)
      view -> view.command?
    end
  end

  @doc "Asks for `sha` of `repo` to be checked, unless it has been or is being."
  def want(repo, sha, server \\ __MODULE__), do: GenServer.cast(server, {:want, repo, sha})

  @doc "`:none`, `{:running, started_at}`, `{:queued, nil}` or the result for `sha`."
  def status(sha, server \\ __MODULE__) do
    case Merge.Board.view({__MODULE__, server}) do
      nil -> GenServer.call(server, {:status, sha})
      view -> status_in(view, result(view, server, :check, sha), sha)
    end
  end

  @doc """
  The image check of `sha`: `:off` without an image command, `:not_needed`,
  `:none`, `{:running, started_at}`, `{:queued, nil}` or its result.
  """
  def image_status(sha, server \\ __MODULE__) do
    case Merge.Board.view({__MODULE__, server}) do
      nil -> GenServer.call(server, {:image_status, sha})
      view -> image_status_in(view, result(view, server, :image, sha), sha)
    end
  end

  # The checks' state is read from the board (`Merge.Board`), where the checks'
  # process publishes it on every change: `view` is who runs and who waits, and
  # each result is a row of its own, so a page copies only the one it shows.
  # No page asks the process, which may be busy checking out a commit.
  defp result(view, server, kind, sha) do
    if sha in Map.fetch!(view.shas, kind),
      do: Merge.Board.view({__MODULE__, server, kind, sha})
  end

  defp status_in(view, result, sha) do
    cond do
      result -> result
      match?(%{kind: :check, sha: ^sha}, view.running) -> {:running, view.running.started_at}
      view.next == sha -> {:queued, nil}
      true -> :none
    end
  end

  defp image_status_in(view, result, sha) do
    waiting? = match?(%{kind: :check, sha: ^sha}, view.running) or view.next == sha

    cond do
      not view.image? -> :off
      result -> result
      match?(%{kind: :image, sha: ^sha}, view.running) -> {:running, view.running.started_at}
      view.image_needed[sha] == false -> :not_needed
      view.image_needed[sha] && waiting? -> {:queued, nil}
      true -> :none
    end
  end

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

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:enabled?, _from, state), do: {:reply, state.command != nil, state}

  # Asked only until this process has published (one running since before the board).
  def handle_call({:status, sha}, _from, state) do
    {:reply, status_in(view(state), state.results[sha], sha), publish(state)}
  end

  def handle_call({:image_status, sha}, _from, state) do
    {:reply, image_status_in(view(state), state.image_results[sha], sha), publish(state)}
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
    state = state |> lost_run() |> decide_image(repo, sha)

    state =
      cond do
        todo(state, sha) == nil -> state
        state.running && state.running.sha == sha -> state
        state.running -> %{state | next: {repo, sha}}
        true -> start(state, repo, sha)
      end

    {:noreply, publish(state)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{running: %{port: port} = run} = state) do
    {:noreply, %{state | running: %{run | log: [data | run.log]}}}
  end

  # Killed from outside (the server stopping takes its commands with it): the
  # commit was not checked, which is not the same as failing.
  def handle_info({port, {:exit_status, status}}, %{running: %{port: port}} = state)
      when status in @signals do
    {:noreply, publish(cut_off(state))}
  end

  def handle_info({port, {:exit_status, status}}, %{running: %{port: port}} = state) do
    {:noreply, publish(finish(state, status == 0))}
  end

  def handle_info({:timeout, kind, sha}, %{running: %{kind: kind, sha: sha, port: port}} = state) do
    Port.close(port)
    state = update_in(state.running.log, &["\n[merge] Stopped after 45 minutes.\n" | &1])
    {:noreply, publish(finish(state, false))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # What pages read (`status/2`, `image_status/2`), and each result in a row of
  # its own; rows of results that were trimmed away go.
  defp view(state) do
    %{
      command?: state.command != nil,
      image?: state.image_command != nil,
      running: state.running && Map.take(state.running, [:kind, :sha, :started_at]),
      next: state.next && elem(state.next, 1),
      image_needed: state.image_needed,
      shas: %{check: Map.keys(state.results), image: Map.keys(state.image_results)}
    }
  end

  defp publish(state) do
    with {:registered_name, server} when is_atom(server) <-
           Process.info(self(), :registered_name) do
      view = view(state)
      shown = Process.get(:shown, %{check: %{}, image: %{}})

      for {kind, results} <- [check: state.results, image: state.image_results] do
        for {sha, result} <- results,
            shown[kind][sha] != result.finished_at,
            do: Merge.Board.put_view({__MODULE__, server, kind, sha}, result)

        for {sha, _} <- shown[kind],
            not is_map_key(results, sha),
            do: Merge.Board.drop_view({__MODULE__, server, kind, sha})
      end

      Process.put(:shown, %{
        check: Map.new(state.results, fn {sha, r} -> {sha, r.finished_at} end),
        image: Map.new(state.image_results, fn {sha, r} -> {sha, r.finished_at} end)
      })

      Merge.Board.put_view({__MODULE__, server}, view)
    end

    state
  end

  # The command is gone and its end never arrived (a message that comes while
  # the code is being loaded is dropped): seen gone on two requests running, a
  # minute apart, the run counts as cut off.
  defp lost_run(%{running: %{port: port} = run} = state) when is_port(port) do
    cond do
      Port.info(port) != nil -> state
      Map.get(run, :gone?) -> cut_off(state)
      true -> %{state | running: Map.put(run, :gone?, true)}
    end
  end

  defp lost_run(state), do: state

  # A run that was cut off leaves no result: the commit shows as not checked
  # and is checked again when it is next asked for (each minute, while it is
  # main's tip). After `@cut_limit` times it is recorded as failed.
  defp cut_off(%{running: run} = state) do
    cuts = Map.get(state, :cuts, %{})
    times = Map.get(cuts, {run.kind, run.sha}, 0) + 1

    if times >= @cut_limit do
      state = update_in(state.running.log, &["\n[merge] Cut off #{times} times.\n" | &1])
      finish(Map.put(state, :cuts, Map.delete(cuts, {run.kind, run.sha})), false)
    else
      if run.timer, do: Process.cancel_timer(run.timer)
      log = IO.iodata_to_binary(Enum.reverse(["\n[merge] Cut off before it ended.\n" | run.log]))
      write_log(state, run.kind, run.sha, log)
      what = if run.kind == :check, do: "checks-not-run", else: "image-not-run"
      Merge.Events.emit(what, "main", "#{Merge.Events.short(run.sha)} cut off, runs again")

      state =
        state
        |> Map.put(:cuts, Map.put(cuts, {run.kind, run.sha}, times))
        |> Map.put(:running, nil)

      broadcast(state, run.sha)

      case state.next do
        {repo, sha} -> start(%{state | next: nil}, repo, sha)
        nil -> state
      end
    end
  end

  defp running?(state, kind, sha),
    do: match?(%{kind: ^kind, sha: ^sha}, state.running)

  # Decided once per commit, against origin/main as it is when the commit is wanted.
  defp decide_image(%{image_command: nil} = state, _repo, _sha), do: state

  defp decide_image(state, repo, sha) do
    if Map.has_key?(state.image_needed, sha) or Map.has_key?(state.image_results, sha) do
      state
    else
      needed = Merge.ImagePaths.needed?(repo, sha)
      # A map has no order to trim by (a small one lists by key), so the commit just
      # decided always stays and others make room.
      needs =
        state.image_needed
        |> Map.delete(sha)
        |> Enum.take(@keep - 1)
        |> Map.new()
        |> Map.put(sha, needed)

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

        broadcast(%{state | running: run}, sha)

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

  # Both go below the web server, the image check lowest: this machine clamps
  # its CPU under load, and a page must not wait behind a test run.
  defp executable(_kind), do: System.find_executable("nice") || System.find_executable("sh")

  defp args(state, kind) do
    {level, command} =
      if kind == :check, do: {"10", state.command}, else: {"19", state.image_command}

    if System.find_executable("nice"),
      do: ["-n", level, "sh", "-c", command],
      else: ["-c", command]
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
      log: log |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n"),
      excerpt: if(ok?, do: nil, else: Merge.Checks.Excerpt.excerpt(log))
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
    broadcast(state, run.sha)

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

  # Published before anyone is told, so whoever hears reads the new state.
  defp broadcast(state, sha) do
    publish(state)
    Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:checks, sha})
    state
  end

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
