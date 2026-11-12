defmodule Merge.Watcher do
  @moduledoc """
  Every minute (`config :merge, :watch_ms`; nil turns it off): fetches
  origin in each repo the merge requests use, broadcasts the drift of main,
  marks merge requests merged when their branch has landed on main, and
  broadcasts the trees and their servers (`Merge.Servers`), and lets
  `Merge.AutoPush` push main when it is due, with a timer for the moment it
  falls due between rounds, and lets `Merge.AutoMerge` merge approved branches
  into main (after each round, and on each approval): all in this one process,
  so one merge runs at a time. Each round first starts any stored merge request
  whose process is gone (`Merge.MergeRequest.restore_missing/0`). `refresh/0` does the round
  at once (the home page asks on load).
  """

  use GenServer

  alias Merge.{Drift, Git, MergeRequest}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Fetches and checks now, in the background."
  def refresh, do: GenServer.cast(__MODULE__, :run)

  @doc "Sets the timer for the auto-push's moment again (the toggle moved)."
  def schedule_auto_push do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :schedule_auto_push)
    :ok
  end

  @doc "Lets Auto Merge look now, at `branch`'s merge request or every approved one."
  def auto_merge(branch \\ nil) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:auto_merge, branch})
    :ok
  end

  @impl true
  def init(nil) do
    # The first round once the stored merge requests are back.
    if interval(), do: Process.send_after(self(), :tick, 5_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    Process.send_after(self(), :tick, interval())
    {:noreply, schedule(state)}
  end

  # The moment the auto-push fell due, between rounds.
  def handle_info(:auto_push, _state) do
    Merge.AutoPush.run()
    {:noreply, schedule(nil)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:run, state) do
    run()
    # Asked again while it ran (each home page load asks): that round was this one.
    drop_runs()
    {:noreply, schedule(state)}
  end

  def handle_cast(:schedule_auto_push, state), do: {:noreply, schedule(state)}

  # A merge moves main, so the auto-push's timer is set again.
  def handle_cast({:auto_merge, branch}, state) do
    Merge.AutoMerge.run(branch)
    {:noreply, schedule(state)}
  end

  defp drop_runs do
    receive do
      {:"$gen_cast", :run} -> drop_runs()
    after
      0 -> :ok
    end
  end

  # One timer at most, for when main's tip falls due (the state is its ref).
  defp schedule(timer) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    case Merge.AutoPush.status(Drift.current()) do
      {:due, at} ->
        ms = max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0) + 500
        Process.send_after(self(), :auto_push, ms)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "One round: fetch, drift, merges, servers."
  def run do
    # A merge request whose process died comes back from its file first.
    MergeRequest.restore_missing()
    mrs = MergeRequest.list()

    [Drift.repo() | Enum.map(mrs, &MergeRequest.git_repo/1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.uniq_by(&common_dir/1)
    |> Enum.each(&Git.fetch/1)

    with %{repo: repo, main: main} <- Drift.refresh(), do: Merge.Checks.want(repo, main)

    # After the fetch, so GitHub's main is as fresh as it gets. Off unless the toggle is
    # on; it reads everything again itself, and holds on anything it can't prove.
    Merge.AutoPush.run()

    Enum.each(mrs, fn mr ->
      MergeRequest.check_branch(mr.branch)
      MergeRequest.check_merged(mr.branch)
    end)

    # After the branches are looked at, so a conflict that is gone is gone here too.
    Merge.AutoMerge.run()

    Merge.Servers.refresh()
  end

  # Worktrees of one repo share a fetch.
  defp common_dir(repo) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
      {dir, 0} -> Path.expand(String.trim(dir), repo)
      _ -> repo
    end
  end

  defp interval, do: Application.get_env(:merge, :watch_ms)
end
