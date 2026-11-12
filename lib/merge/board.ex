defmodule Merge.Board do
  @moduledoc """
  What the pages and the commands read: each merge request as its process last
  published it, in a table anyone reads without asking that process. So a page
  never waits behind a merge request that is busy (reading its branch from
  git, say), and can't be told it is gone because the answer took too long.

  Each merge request's process is the only writer of its rows, on every
  change: the whole of it (with the diff) for its own page, and a summary
  without the diff for lists. A row outlives its process: one that died stays
  listed as it was until `Merge.MergeRequest.restore_missing/0` starts it again
  from disk; one that makes way for a new one on its branch removes its rows.

  This process only owns the table. A server that loaded this code while
  running (no restart) has no such child yet: `put/3` starts it then.
  """

  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Publishes a merge request: `full` with its diff, `summary` without."
  def put(branch, full, summary) do
    ensure()
    :ets.insert(@table, [{{:full, branch}, full}, {{:summary, branch}, summary}])
    :ok
  end

  @doc """
  Leaves only the summary of a merge request on the board: one that is
  finished and resting has no process and no diff in memory
  (`Merge.MergeRequest.rest/1`); its page reads the diff from its file.
  """
  def put_resting(branch, summary) do
    ensure()
    :ets.insert(@table, {{:summary, branch}, summary})
    :ets.delete(@table, {:full, branch})
    :ok
  end

  @doc "One merge request's summary, or nil."
  def summary(branch) do
    with true <- up?(), [{_, summary}] <- :ets.lookup(@table, {:summary, branch}) do
      summary
    else
      _ -> nil
    end
  end

  @doc "Takes a merge request off the board."
  def delete(branch) do
    if up?() do
      :ets.delete(@table, {:full, branch})
      :ets.delete(@table, {:summary, branch})
    end

    :ok
  end

  @doc "The merge request for `branch` with its diff, or nil when it isn't on the board."
  def get(branch) do
    with true <- up?(), [{_, full}] <- :ets.lookup(@table, {:full, branch}) do
      full
    else
      _ -> nil
    end
  end

  @doc "Every summary on the board, by branch."
  def summaries do
    if up?(),
      do: Map.new(:ets.match(@table, {{:summary, :"$1"}, :"$2"}), fn [b, s] -> {b, s} end),
      else: %{}
  end

  @doc """
  Keeps one other thing for pages to read without asking its process (the
  checks' state): `view/1` reads it, nil when there is none.
  """
  def put_view(key, value) do
    ensure()
    :ets.insert(@table, {{:view, key}, value})
    :ok
  end

  def view(key) do
    with true <- up?(), [{_, value}] <- :ets.lookup(@table, {:view, key}) do
      value
    else
      _ -> nil
    end
  end

  def drop_view(key) do
    if up?(), do: :ets.delete(@table, {:view, key})
    :ok
  end

  defp up?, do: :ets.whereis(@table) != :undefined

  defp ensure do
    unless up?() do
      # Already started by another writer at the same moment is as good.
      _ = Supervisor.start_child(Merge.Supervisor, __MODULE__)
    end
  end
end
