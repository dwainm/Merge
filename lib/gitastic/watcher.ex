defmodule Gitastic.Watcher do
  @moduledoc """
  Every minute (`config :gitastic, :watch_ms`; nil turns it off): fetches
  origin in each repo the merge requests use, broadcasts the drift of main,
  and marks merge requests merged when their branch has landed on main.
  `refresh/0` does the same at once (the home page asks on load).
  """

  use GenServer

  alias Gitastic.{Drift, Git, MergeRequest}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Fetches and checks now, in the background."
  def refresh, do: GenServer.cast(__MODULE__, :run)

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
    {:noreply, state}
  end

  @impl true
  def handle_cast(:run, state) do
    run()
    {:noreply, state}
  end

  @doc "One round: fetch, drift, merges."
  def run do
    mrs = MergeRequest.list()

    [Drift.repo() | Enum.map(mrs, &MergeRequest.git_repo/1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&common_dir/1)
    |> Enum.each(&Git.fetch/1)

    with %{repo: repo, main: main} <- Drift.refresh(), do: Gitastic.Checks.want(repo, main)

    Enum.each(mrs, fn mr ->
      MergeRequest.check_branch(mr.branch)
      MergeRequest.check_merged(mr.branch)
    end)
  end

  # Worktrees of one repo share a fetch.
  defp common_dir(repo) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
      {dir, 0} -> Path.expand(String.trim(dir), repo)
      _ -> repo
    end
  end

  defp interval, do: Application.get_env(:gitastic, :watch_ms)
end
