defmodule Gitastic.Queue do
  @moduledoc """
  The reviewer's queue: merge requests added with "Add to queue", shown as tabs
  at the top of every page, oldest first; the first still in review is "Next".

  Once one is approved, merged or closed it stays for `linger_ms/0`, fading,
  then drops out. That is worked out from the merge request when the tabs are
  read, so no timer has to survive a restart.

  Kept with the merge requests (a named term) and cached in `:persistent_term`;
  changes are broadcast on `topic/0` as `:queue_changed`.
  """

  alias Gitastic.MergeRequest

  @linger_ms 15_000

  def topic, do: "queue"
  def linger_ms, do: @linger_ms

  @doc "The queued branches as `%{branch, added_at}`, oldest first."
  def entries do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        entries = Gitastic.Store.get_named("queue") || []
        :persistent_term.put(__MODULE__, entries)
        entries

      entries ->
        entries
    end
  end

  def queued?(branch), do: Enum.any?(entries(), &(&1.branch == branch))

  def add(branch) do
    if queued?(branch),
      do: :ok,
      else: put(entries() ++ [%{branch: branch, added_at: DateTime.utc_now()}])
  end

  def remove(branch), do: put(Enum.reject(entries(), &(&1.branch == branch)))

  @doc """
  The tabs, from the queue and the merge requests: `%{branch, title, status,
  added_at, leaving_at, next}`. `leaving_at` is when a decided one drops out
  (nil while in review); `next` marks the first still in review.
  """
  def tabs(now \\ DateTime.utc_now()) do
    mrs = Map.new(MergeRequest.list(), &{&1.branch, &1})

    tabs =
      for entry <- entries(), mr = mrs[entry.branch], mr != nil do
        %{
          branch: mr.branch,
          title: mr.title,
          status: mr.status,
          added_at: entry.added_at,
          leaving_at: leaving_at(mr),
          next: false
        }
      end
      |> Enum.filter(&(&1.leaving_at == nil or DateTime.compare(&1.leaving_at, now) == :gt))

    case Enum.find_index(tabs, &(&1.leaving_at == nil)) do
      nil -> tabs
      i -> List.update_at(tabs, i, &%{&1 | next: true})
    end
  end

  # Approved, merged or closed: it goes a little after that happened.
  defp leaving_at(%{status: status} = mr) when status in [:approved, :merged, :closed] do
    decided =
      case {status, List.last(mr.decisions)} do
        {:approved, %{at: at}} -> at
        _ -> mr.done_at || DateTime.utc_now()
      end

    DateTime.add(decided, @linger_ms, :millisecond)
  end

  defp leaving_at(_mr), do: nil

  defp put(entries) do
    # Ones whose merge request has gone are dropped on the way.
    open = MapSet.new(MergeRequest.list(), & &1.branch)
    entries = Enum.filter(entries, &MapSet.member?(open, &1.branch))
    :persistent_term.put(__MODULE__, entries)
    Gitastic.Store.put_named("queue", entries)
    Phoenix.PubSub.broadcast(Gitastic.PubSub, topic(), :queue_changed)
    :ok
  end
end
