defmodule Merge.LiveStatus do
  @moduledoc """
  What is true in each open merge request's work folder, read every few
  seconds: what its status file says (`Merge.StatusFile`), whether it has
  changes to tracked files that aren't committed, and whether its test site
  answers. `verdict/2` turns that and the merge request into what a person
  sees: "Ready to review" only when the file says so, nothing tracked is left
  uncommitted, and the test site answers (where the tree has one); otherwise
  what is in the way, in a few words.

  The test site is the tree's `.dev-url` (the app's dev tunnel writes it),
  else `http://localhost:<port>` of a server listening from inside the tree.
  A tree with a `.dev-url` and no server listening is down ("no server
  running"); one with neither has no test site, and no such line. A GET with
  no redirect followed, 5 seconds at most: below 500 is up (`Merge.Servers.probe/2`).

  ## The round

  One process (`start_link/1`), one round at a time, the next
  `config :merge, :live_ms` after the last ended (15 s; nil in the tests,
  which call `run/1`). `poke/0` asks for a round now (a merge request's page
  does on load); pokes during a round make one more round after it, never a
  pile. In a round each tree is read in a task of its own, with a time limit:
  `git --no-optional-locks status --porcelain --untracked-files=no` (no index
  lock, so a stream's own commit never trips on it) under `timeout 8`, the
  file, and the probe. A tree that runs out of time keeps its last reading.
  Per round that is one `git worktree list` per repo, one `ss`, and per open
  merge request one `git status`, one small file read and one GET.

  What it read goes on the board (`Merge.Board`, view `:live`), never by
  asking this process, and is broadcast on `topic/0` as `{:live, map}`.

  ## What it changes

  The file is the stream's word, so the merge request follows it: a file that
  turns to `in progress` while it is Needs review makes it In progress, with
  the note (as `mr working` does: the `working` event, and the other agents
  hear it); one that turns to `ready to review` while it is In progress hands
  it back (as `mr addressed` does, without a commit). Only a change of the
  file does this, so a Reject (which writes `in progress` itself) never races
  an old `ready to review`.

  When what a person sees changes, it is an event: `ready-to-review <branch>`,
  or `not-ready <branch> <what is in the way>` (said again only when what is
  in the way changes, not when a count does). Not on the first reading after
  a start: nothing changed then that anyone saw.
  """

  use GenServer

  alias Merge.{Board, Events, Git, MergeRequest, Servers, StatusFile}

  def topic, do: "live_status"

  ## Reading it

  @doc "The last reading of every open merge request, by branch."
  def all, do: Board.view(:live) || %{}

  @doc "The last reading for `branch`, or nil."
  def get(branch), do: Map.get(all(), branch)

  @doc "The work folder `branch` was last seen checked out in, or nil."
  def tree(branch), do: with(%{tree: tree} <- get(branch), do: tree)

  ## The verdict

  @doc """
  What a person sees of an open merge request (Needs review or In progress
  in the store), from it and its reading: `%{ready?, label, tone, reasons}`,
  `reasons` a list of `{kind, text}` in the order they matter. nil for one
  that is approved, merged or closed.

  `kind` is `:in_progress`, `:not_said` (no status file, or one that says
  something else), `:changes` (tracked files not committed) or `:site_down`.
  `tone` is `:ready`, `:working`, `:down` or `:unsaid`. `ready?` with no
  tree read means only that the commands said so: its label is "Needs review".
  """
  def verdict(%{status: status} = mr, live) when status in [:open, :in_progress] do
    # No tree read: nothing on disk to say otherwise than the commands did.
    {said, read?} =
      case live do
        %{tree: tree, said: said} when is_binary(tree) -> {said, true}
        _ -> {stored_said(mr), false}
      end

    # Put In progress (a Reject, `mr working`) and the file not caught up: In
    # progress. A file that turns ready hands it back first (`follow/3`).
    said =
      case {said, mr.status} do
        {{:ready, _}, :in_progress} -> stored_said(mr)
        _ -> said
      end

    reasons =
      [
        said_reason(said),
        changes_reason(live),
        site_reason(live)
      ]
      |> Enum.reject(&is_nil/1)

    {label, tone} =
      case reasons do
        [] when read? -> {"Ready to review", :ready}
        [] -> {"Needs review", :ready}
        [{:in_progress, _} | _] -> {"In progress", :working}
        [{:not_said, _} | _] -> {"Not said", :unsaid}
        [{:changes, _} | _] -> {"Being changed", :working}
        [{:site_down, _} | _] -> {"Test site down", :down}
      end

    %{ready?: reasons == [], label: label, tone: tone, reasons: reasons, said: said}
  end

  def verdict(_mr, _live), do: nil

  @doc "The verdict in one line, for `mr list` and the events: `Being changed: 3 files not committed`."
  def line(nil), do: nil
  def line(%{ready?: true, label: label}), do: label

  def line(%{label: label, reasons: [{kind, _} | _] = reasons}) do
    texts = Enum.map(reasons, &elem(&1, 1))

    # "In progress: …" and "Test site is down" say their label themselves.
    if kind in [:in_progress, :site_down],
      do: Enum.join(texts, "; "),
      else: label <> ": " <> (texts |> Enum.map(&lower_first/1) |> Enum.join("; "))
  end

  defp lower_first(<<c::utf8, rest::binary>>), do: String.downcase(<<c::utf8>>) <> rest
  defp lower_first(text), do: text

  # No tree: what the commands last said.
  defp stored_said(%{status: :in_progress} = mr) do
    {:in_progress, with(%{note: note} <- MergeRequest.working_note(mr), do: note)}
  end

  defp stored_said(_mr), do: {:ready, nil}

  defp said_reason({:ready, _}), do: nil
  defp said_reason({:in_progress, nil}), do: {:in_progress, "In progress"}
  defp said_reason({:in_progress, note}), do: {:in_progress, "In progress: " <> note}
  defp said_reason({:unclear, text}), do: {:not_said, "Status file says \"#{text}\""}
  defp said_reason(_none), do: {:not_said, "No status file"}

  defp changes_reason(%{changes: n}) when is_integer(n) and n > 0,
    do: {:changes, "#{n} #{if n == 1, do: "file", else: "files"} not committed"}

  defp changes_reason(_live), do: nil

  defp site_reason(%{site: %{state: :down, reason: reason}}),
    do: {:site_down, "Test site is down" <> if(reason, do: " (#{reason})", else: "")}

  defp site_reason(_live), do: nil

  ## The round

  @doc """
  One round, at once, in the caller: reads every open merge request's tree,
  lets the merge requests follow their files, publishes and broadcasts, and
  emits the events. Returns the readings by branch. `opts`: `:listeners`
  (`Merge.Servers.listeners/0`'s map) and `:req` (given to the probe; tests
  pass a `plug:`), and `:only` (these branches alone; the others' readings
  are kept as they were).
  """
  def run(opts \\ []) do
    previous = all()
    only = opts[:only]

    mrs =
      MergeRequest.list()
      |> Enum.filter(&(&1.status in [:open, :in_progress]))
      |> Enum.filter(&(only == nil or &1.branch in only))

    listeners = Keyword.get_lazy(opts, :listeners, &Servers.listeners/0)
    req = Keyword.get(opts, :req, [])
    trees = trees(mrs)

    readings =
      mrs
      |> Task.async_stream(
        fn mr -> read_tree(Map.get(trees, mr.branch), listeners, req, previous[mr.branch]) end,
        timeout: 15_000,
        on_timeout: :kill_task,
        max_concurrency: 8
      )
      |> Enum.zip(mrs)
      |> Map.new(fn
        {{:ok, reading}, mr} -> {mr.branch, reading}
        # Out of time: what was read last stands.
        {{:exit, _}, mr} -> {mr.branch, previous[mr.branch] || empty(Map.get(trees, mr.branch))}
      end)

    readings =
      Map.new(mrs, fn mr ->
        reading = readings[mr.branch]
        mr = follow(mr, reading, previous[mr.branch])
        verdict = verdict(mr, reading)
        key = key(verdict)

        case previous[mr.branch] do
          %{key: ^key} -> :ok
          %{} -> emit(mr.branch, verdict)
          nil -> :ok
        end

        {mr.branch, Map.put(reading, :key, key)}
      end)

    all = if only, do: previous |> Map.drop(only) |> Map.merge(readings), else: readings
    Board.put_view(:live, all)
    Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:live, all})
    note_sites(readings)
    readings
  end

  # The branch → the worktree it is checked out in, one `git worktree list` per repo.
  defp trees(mrs) do
    mrs
    |> Enum.group_by(&MergeRequest.git_repo/1)
    |> Enum.flat_map(fn {repo, mrs} ->
      by_branch = Map.new(Git.worktrees(repo), &{&1.branch, &1.path})
      Enum.flat_map(mrs, &if(path = by_branch[&1.branch], do: [{&1.branch, path}], else: []))
    end)
    |> Map.new()
  end

  defp empty(tree), do: %{tree: tree, said: :none, changes: nil, site: none(), at: now()}

  defp none, do: %{state: :none, url: nil, reason: nil}

  defp read_tree(nil, _listeners, _req, _previous), do: empty(nil)

  defp read_tree(tree, listeners, req, previous) do
    changes =
      case changes(tree) do
        :unknown -> previous && previous[:tree] == tree && previous[:changes]
        n -> n
      end

    %{
      tree: tree,
      said: StatusFile.read(tree),
      changes: if(is_integer(changes), do: changes),
      site: site(tree, listeners, req),
      at: now()
    }
  end

  @doc """
  How many tracked files in `tree` have changes that aren't committed, staged
  or not; the status file never counts. `:unknown` when git didn't answer in
  time or failed.
  """
  def changes(tree) do
    args = ["--no-optional-locks", "-C", tree, "status", "--porcelain", "--untracked-files=no"]

    case System.cmd("timeout", ["-k", "2", "8", "git" | args], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reject(&(String.slice(&1, 3..-1//1) == StatusFile.name()))
        |> length()

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  @doc """
  The tree's test site: `%{state, url, reason}`, `state` `:up`, `:down` or
  `:none` (it has no test site).
  """
  def site(tree, listeners, req \\ []) do
    ports =
      listeners
      |> Enum.filter(fn {cwd, _} -> cwd == tree or String.starts_with?(cwd, tree <> "/") end)
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.map(& &1.port)
      |> Enum.sort()

    dev_url = Servers.dev_url(tree)

    cond do
      ports == [] and dev_url == nil ->
        none()

      ports == [] ->
        %{state: :down, url: dev_url, reason: "no server running"}

      true ->
        url = dev_url || "http://localhost:#{hd(ports)}"

        case Servers.probe(url, req) do
          {:up, _} -> %{state: :up, url: url, reason: nil}
          {_status, reason} -> %{state: :down, url: url, reason: reason}
        end
    end
  end

  # The merge request follows its file, when the file changed (or was first seen).
  defp follow(mr, %{tree: tree, said: said}, previous) when is_binary(tree) do
    changed? = previous == nil or previous[:said] != said or previous[:tree] != tree

    result =
      case {changed?, said, mr.status} do
        {true, {:in_progress, note}, :open} ->
          MergeRequest.working(mr.branch, note, mr.opened_by, false)

        {true, {:ready, note}, :in_progress} ->
          MergeRequest.ready(mr.branch, note, mr.opened_by)

        _ ->
          :same
      end

    case result do
      {:ok, _} -> Board.summary(mr.branch) || mr
      _ -> mr
    end
  end

  defp follow(mr, _reading, _previous), do: mr

  defp key(nil), do: nil
  defp key(%{ready?: true}), do: :ready
  defp key(%{reasons: reasons}), do: Enum.map(reasons, &elem(&1, 0))

  defp emit(_branch, nil), do: :ok
  defp emit(branch, %{ready?: true}), do: Events.emit("ready-to-review", branch)

  defp emit(branch, %{reasons: reasons}),
    do: Events.emit("not-ready", branch, reasons |> Enum.map(&elem(&1, 1)) |> Enum.join("; "))

  # The trees' racks say what the probe found too, so the page never shows a
  # green server beside "Test site is down".
  defp note_sites(readings) do
    for {_branch, %{tree: tree, site: %{state: state, reason: reason}}} <- readings,
        is_binary(tree) and state != :none do
      Servers.note_status(tree, if(state == :up, do: {:up, nil}, else: down(reason)))
    end

    :ok
  end

  defp down("no server running"), do: {:off, nil}
  defp down("not answering"), do: {:not_answering, "not answering"}
  defp down(reason), do: {:error, reason}

  defp now, do: DateTime.utc_now()

  ## The process

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Asks for a round now. Returns at once; one under way is followed by one
  more. Nothing where the rounds are off (the tests call `run/1`).
  """
  def poke do
    cond do
      interval() == nil -> :ok
      Process.whereis(__MODULE__) -> GenServer.cast(__MODULE__, :poke)
      # A server that loaded this code while running has no such process yet.
      true -> Supervisor.start_child(Merge.Supervisor, __MODULE__)
    end

    :ok
  end

  @impl true
  def init(nil) do
    # The first round once the stored merge requests are back.
    if interval(), do: Process.send_after(self(), :tick, 3_000)
    {:ok, %{round: nil, again: false, timer: nil}}
  end

  @impl true
  def handle_cast(:poke, state), do: {:noreply, start(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, start(%{state | timer: nil})}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{round: ref} = state) do
    if reason != :normal do
      require Logger
      Logger.warning("Merge.LiveStatus round failed: #{inspect(reason)}")
    end

    state = %{state | round: nil}
    if state.again, do: {:noreply, start(%{state | again: false})}, else: {:noreply, arm(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start(%{round: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {_pid, ref} = spawn_monitor(fn -> run() end)
    %{state | round: ref, timer: nil}
  end

  defp start(state), do: %{state | again: true}

  defp arm(state) do
    case interval() do
      nil -> state
      ms -> %{state | timer: Process.send_after(self(), :tick, ms)}
    end
  end

  defp interval, do: Application.get_env(:merge, :live_ms)
end
