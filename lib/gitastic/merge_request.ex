defmodule Gitastic.MergeRequest do
  @moduledoc """
  One process per open merge request, registered by branch. It holds everything
  about the merge request (there is no database): the branch and base, title,
  body, who opened it, the comments, the decisions, what was addressed, the
  commits and the current diff, and the agents waiting to hear a decision.

  The review goes in rounds. A comment belongs to the round it was written in
  (the number of decisions before it); a decision closes its round and tells
  every waiting agent, with the round's comments; `addressed/4` answers the last
  decision with a commit and a note, recomputes the diff and opens the next round.

  Every change is broadcast on `topic(branch)` as `{:merge_request, mr}`, and
  `"merge_requests"` hears `:merge_requests_changed` when one opens, changes or closes.
  """

  use GenServer, restart: :temporary

  alias Gitastic.Git

  @list_topic "merge_requests"

  defstruct [
    :branch,
    :base,
    :repo,
    :title,
    :body,
    :opened_by,
    :opened_at,
    :head,
    :merge_base,
    status: :open,
    agents: [],
    comments: [],
    decisions: [],
    addressed: [],
    commits: [],
    files: [],
    waiters: %{},
    next_id: 1
  ]

  ## API

  def topic(branch), do: "merge_request:" <> branch
  def list_topic, do: @list_topic

  @doc """
  Opens a merge request for `attrs.branch` in `attrs.repo`, or, when one is
  already open for the branch, registers the opener on it. Returns
  `{:ok, mr, :opened | :existing}`.
  """
  def open(attrs) do
    attrs = Map.new(attrs)
    branch = Map.fetch!(attrs, :branch)

    case lookup(branch) do
      {:ok, pid} ->
        GenServer.call(pid, {:register, attrs[:opened_by]})
        {:ok, get!(branch), :existing}

      :error ->
        case DynamicSupervisor.start_child(Gitastic.MergeRequests, {__MODULE__, attrs}) do
          {:ok, _pid} -> {:ok, get!(branch), :opened}
          {:error, {:already_started, _pid}} -> open(attrs)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def start_link(attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(attrs.branch))
  end

  @doc "Every open merge request, oldest first."
  def list do
    Gitastic.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn branch ->
      case get(branch) do
        {:ok, mr} -> [mr]
        :error -> []
      end
    end)
    |> Enum.sort_by(& &1.opened_at, DateTime)
  end

  @doc "The merge request for a branch; `waiting` names the agents blocked in `wait/3`."
  def get(branch), do: call(branch, :get)

  defp get!(branch) do
    {:ok, mr} = get(branch)
    mr
  end

  @doc """
  Adds a comment. `attrs` has `:body` and optionally `:author`, and for a line
  comment `:path`, `:line`, `:side` (`"new"` or `"old"`) and `:commit` (the
  commit whose diff it was written on, nil for the whole branch).
  """
  def comment(branch, attrs), do: call(branch, {:comment, Map.new(attrs)})

  @doc """
  Approves (`:approved`) or rejects (`:needs_work`) the merge request, closing
  the round and telling every waiting agent. A rejection needs a comment, or a
  comment already written in this round.
  """
  def decide(branch, verdict, body \\ "", by \\ "reviewer")
      when verdict in [:approved, :needs_work] do
    call(branch, {:decide, verdict, String.trim(body || ""), by})
  end

  @doc "Records that `commit` addresses the last decision, recomputes the diff and starts a new round."
  def addressed(branch, commit, note \\ nil, by \\ nil),
    do: call(branch, {:addressed, commit, note, by})

  @doc """
  Waits for a decision. When the last decision has not been addressed yet, it is
  the answer at once; otherwise this blocks until the next decision, the merge
  request closing, or `timeout` ms, answering `{:ok, outcome}` or `{:ok, :timeout}`.
  """
  def wait(branch, name, timeout) do
    case lookup(branch) do
      {:ok, pid} -> GenServer.call(pid, {:wait, name, timeout}, timeout + 5_000)
      :error -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Ends the merge request: waiting agents are told it closed, and the process stops."
  def close(branch), do: call(branch, :close)

  defp call(branch, msg) do
    case lookup(branch) do
      {:ok, pid} -> GenServer.call(pid, msg)
      :error -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp lookup(branch) do
    case Registry.lookup(Gitastic.Registry, branch) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via(branch), do: {:via, Registry, {Gitastic.Registry, branch}}

  ## Server

  @impl true
  def init(attrs) do
    repo = Path.expand(attrs[:repo] || File.cwd!())
    base = blank_to_nil(attrs[:base]) || Git.default_base(repo)
    branch = attrs.branch

    with {:ok, _} <- Git.rev_parse(repo, base),
         {:ok, _} <- Git.rev_parse(repo, branch) do
      opened_by = blank_to_nil(attrs[:opened_by]) || "agent"

      state =
        %__MODULE__{
          branch: branch,
          base: base,
          repo: repo,
          title: blank_to_nil(attrs[:title]) || branch,
          body: attrs[:body] || "",
          opened_by: opened_by,
          opened_at: DateTime.utc_now(),
          agents: [opened_by]
        }
        |> refresh()

      broadcast_list()
      {:ok, state}
    else
      {:error, message} -> {:stop, message}
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {:ok, public(state)}, state}

  def handle_call({:register, name}, _from, state) do
    {:reply, :ok, register(state, name)}
  end

  def handle_call({:comment, attrs}, _from, state) do
    case blank_to_nil(attrs[:body]) do
      nil ->
        {:reply, {:error, "A comment needs some text."}, state}

      body ->
        comment = %{
          id: state.next_id,
          body: body,
          author: blank_to_nil(attrs[:author]) || "reviewer",
          path: attrs[:path],
          line: attrs[:line],
          side: attrs[:side] || "new",
          commit: blank_to_nil(attrs[:commit]),
          round: length(state.decisions),
          at: DateTime.utc_now()
        }

        state = %{state | comments: state.comments ++ [comment], next_id: state.next_id + 1}
        {:reply, {:ok, comment}, changed(state)}
    end
  end

  def handle_call({:decide, verdict, body, by}, _from, state) do
    round = length(state.decisions)
    round_comments = Enum.filter(state.comments, &(&1.round == round))

    if verdict == :needs_work and body == "" and round_comments == [] do
      {:reply, {:error, "Say what needs work."}, state}
    else
      decision = %{
        verdict: verdict,
        body: body,
        by: by,
        head: state.head,
        round: round,
        at: DateTime.utc_now()
      }

      state = %{state | decisions: state.decisions ++ [decision], status: verdict}
      state = changed(tell_waiters(state, outcome(state)))
      {:reply, {:ok, decision}, state}
    end
  end

  def handle_call({:addressed, commit, note, by}, _from, state) do
    with {:ok, sha} <- Git.rev_parse(state.repo, commit),
         true <- Git.on_branch?(state.repo, sha, state.branch) || {:error, :not_on_branch} do
      entry = %{
        sha: sha,
        short: String.slice(sha, 0, 7),
        note: blank_to_nil(note),
        by: blank_to_nil(by) || state.opened_by,
        # The round it answers: the last decision's.
        round: length(state.decisions) - 1,
        at: DateTime.utc_now()
      }

      state = %{state | addressed: state.addressed ++ [entry], status: :open} |> refresh()
      {:reply, {:ok, entry}, changed(state)}
    else
      {:error, :not_on_branch} ->
        {:reply, {:error, "#{commit} is not on #{state.branch}."}, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:wait, name, timeout}, {pid, _} = from, state) do
    state = register(state, name)

    if state.status in [:approved, :needs_work] do
      {:reply, {:ok, outcome(state)}, state}
    else
      ref = Process.monitor(pid)
      timer = Process.send_after(self(), {:wait_timeout, ref}, timeout)
      {:noreply, changed(%{state | waiters: Map.put(state.waiters, ref, {from, timer, name})})}
    end
  end

  def handle_call(:close, _from, state) do
    state = %{state | status: :closed}
    state = tell_waiters(state, outcome(state))
    # Unregister first, so a page that refetches the list on this broadcast no longer sees it.
    Registry.unregister(Gitastic.Registry, state.branch)
    broadcast(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:wait_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {{from, _timer, _name}, waiters} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:ok, :timeout})
        {:noreply, %{state | waiters: waiters}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.waiters, ref) do
      {{_from, timer, _name}, waiters} ->
        Process.cancel_timer(timer)
        {:noreply, changed(%{state | waiters: waiters})}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: broadcast_list()

  ## Helpers

  defp register(state, name) do
    case blank_to_nil(name) do
      nil -> state
      name -> if name in state.agents, do: state, else: %{state | agents: state.agents ++ [name]}
    end
  end

  defp tell_waiters(state, outcome) do
    for {ref, {from, timer, _name}} <- state.waiters do
      Process.cancel_timer(timer)
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:ok, outcome})
    end

    %{state | waiters: %{}}
  end

  # What a waiting agent is told: the decision (nil when closed), the comments
  # of its round, and every comment before it.
  defp outcome(state) do
    decision = List.last(state.decisions)
    round = if decision, do: decision.round, else: length(state.decisions)

    %{
      branch: state.branch,
      status: state.status,
      decision: decision,
      comments: Enum.filter(state.comments, &(&1.round == round)),
      earlier: Enum.filter(state.comments, &(&1.round < round)),
      addressed: state.addressed
    }
  end

  # Recomputes the commits and the diff of the branch from git.
  defp refresh(state) do
    {:ok, head} = Git.rev_parse(state.repo, state.branch)

    merge_base =
      case Git.merge_base(state.repo, state.base, state.branch) do
        {:ok, sha} -> sha
        {:error, _} -> nil
      end

    commits =
      case Git.commits(state.repo, state.base, state.branch) do
        {:ok, commits} -> commits
        {:error, _} -> []
      end

    files =
      case Git.branch_diff(state.repo, state.base, state.branch) do
        {:ok, files} -> files
        {:error, _} -> []
      end

    %{state | head: head, merge_base: merge_base, commits: commits, files: files}
  end

  defp changed(state) do
    broadcast(state)
    state
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Gitastic.PubSub,
      topic(state.branch),
      {:merge_request, public(state)}
    )

    broadcast_list()
  end

  defp broadcast_list do
    Phoenix.PubSub.broadcast(Gitastic.PubSub, @list_topic, :merge_requests_changed)
  end

  # `waiting` names the agents blocked in `wait/3` right now.
  defp public(state) do
    waiting = state.waiters |> Map.values() |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    state |> Map.from_struct() |> Map.delete(:waiters) |> Map.put(:waiting, waiting)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
