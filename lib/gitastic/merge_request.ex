defmodule Gitastic.MergeRequest do
  @moduledoc """
  One process per merge request, registered by branch. It holds everything
  about the merge request: the branch and base, title, body, who opened it, the
  comments, the decisions, what was addressed, the commits and the current diff,
  and the agents waiting to hear a decision. Every change is also written to
  disk (`Gitastic.Store`), and `restore_all/0` brings them back after a restart;
  waiting agents are not kept, their `wait` asks again.

  The review goes in rounds. A comment belongs to the round it was written in
  (the number of decisions before it); a decision closes its round; `addressed/4`
  answers the last decision with a commit and a note, recomputes the diff and
  opens the next round.

  Agents hear every comment and every decision. Each one gets the next number
  (`seq`), and each agent has a cursor: the last number it was told. `wait/3`
  answers at once with whatever is past the agent's cursor, or blocks until
  there is some, so nothing said while an agent re-arms its wait is missed.

  Merging is read from git: once the branch head is on local `main` the merge
  request is `:merged`, with the merge commit in `merged` (`pushed: false`
  until that commit is on `origin/main` too). `merged/2` marks it when the
  coordinator merges; `Gitastic.Watcher` calls `check_merged/1` every minute.

  Closing doesn't end the process: the merge request is done, `:merged` when its
  last decision was an approval and `:closed` otherwise, and stays to look back
  at, read-only, with the diff as it was, until the server stops or the branch
  is opened again.

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
    :done_at,
    :merged,
    :git_dir,
    status: :open,
    agents: [],
    comments: [],
    decisions: [],
    addressed: [],
    commits: [],
    files: [],
    waiters: %{},
    next_id: 1,
    seq: 0,
    cursors: %{}
  ]

  ## API

  def topic(branch), do: "merge_request:" <> branch
  def list_topic, do: @list_topic

  @doc """
  Where to run git for a merge request: the repo or worktree it was opened in,
  or, once that worktree is removed (streams remove theirs after a merge), the
  repo's shared git directory, kept at open (or, for one opened before that was
  kept, the nearest enclosing repo).
  """
  def git_repo(mr) do
    cond do
      File.dir?(mr.repo) -> mr.repo
      dir = Map.get(mr, :git_dir) -> dir
      true -> Git.enclosing_repo(mr.repo) || mr.repo
    end
  end

  @doc "True once a merge request is merged or closed."
  def done?(%{status: status}), do: status in [:merged, :closed]

  @doc """
  Opens a merge request for `attrs.branch` in `attrs.repo`, or, when one is
  already open for the branch, registers the opener on it. A done one for the
  branch makes way for the new one. Returns `{:ok, mr, :opened | :existing}`.
  """
  def open(attrs) do
    attrs = Map.new(attrs)
    branch = Map.fetch!(attrs, :branch)

    case lookup(branch) do
      {:ok, pid} ->
        case GenServer.call(pid, {:register, attrs[:opened_by]}) do
          :ok -> {:ok, get!(branch), :existing}
          :done -> open(attrs)
        end

      :error ->
        case DynamicSupervisor.start_child(Gitastic.MergeRequests, {__MODULE__, attrs}) do
          {:ok, _pid} -> {:ok, get!(branch), :opened}
          {:error, {:already_started, _pid}} -> open(attrs)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def start_link({:restore, state}) do
    GenServer.start_link(__MODULE__, {:restore, state}, name: via(state.branch))
  end

  def start_link(attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(attrs.branch))
  end

  @doc "Starts a process for every stored merge request that isn't running. Returns how many."
  def restore_all do
    Gitastic.Store.all()
    |> Enum.count(fn state ->
      match?(
        {:ok, _},
        DynamicSupervisor.start_child(Gitastic.MergeRequests, {__MODULE__, {:restore, state}})
      )
    end)
  end

  @doc "Every merge request: the open ones oldest first, then the done ones, latest first."
  def list do
    Gitastic.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn branch ->
      case get(branch) do
        {:ok, mr} -> [mr]
        :error -> []
      end
    end)
    |> Enum.split_with(&(not done?(&1)))
    |> then(fn {open, done} ->
      Enum.sort_by(open, & &1.opened_at, DateTime) ++
        Enum.sort_by(done, & &1.done_at, {:desc, DateTime})
    end)
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
  Waits for news for the agent `name`: a comment or a decision it hasn't been
  told yet, or the merge request closing. Answers at once when there is some;
  otherwise blocks until there is, or `timeout` ms. Answers `{:ok, outcome}`
  (`kind` is `:comment`, `:decision` or `:closed`) or `{:ok, :timeout}`.
  """
  def wait(branch, name, timeout) do
    case lookup(branch) do
      {:ok, pid} -> GenServer.call(pid, {:wait, name, timeout}, timeout + 5_000)
      :error -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Marks it merged into main: at `commit`, or at the commit on main (else on
  origin/main) that brought the branch head in. Answers `{:ok, merged}` or
  `{:error, message}` when the branch isn't on main.
  """
  def merged(branch, commit \\ nil), do: call(branch, {:merged, commit, :manual})

  @doc "Marks it merged if git says it is, and notes when the merge reaches origin/main."
  def check_merged(branch), do: call(branch, {:merged, nil, :auto})

  @doc "Marks it merged (when approved) or closed, and tells the waiting agents. It stays, read-only."
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
  def init({:restore, saved}) do
    # Fields added since it was saved take their defaults.
    {:ok, struct(__MODULE__, saved |> Map.put(:waiters, %{}) |> number_events())}
  end

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
          agents: [opened_by],
          git_dir: Git.common_dir(repo)
        }
        |> refresh()

      Gitastic.Store.put(saved(state))
      broadcast_list()
      {:ok, state}
    else
      {:error, message} -> {:stop, message}
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {:ok, public(state)}, state}

  # A done merge request steps aside for a new one on the same branch: it
  # unregisters itself before it stops, so the branch is free at once.
  def handle_call({:register, _name}, _from, %{status: status} = state)
      when status in [:merged, :closed] do
    Registry.unregister(Gitastic.Registry, state.branch)
    {:stop, :normal, :done, state}
  end

  def handle_call({:register, name}, _from, state) do
    state = register(state, name)
    Gitastic.Store.put(saved(state))
    {:reply, :ok, state}
  end

  def handle_call({:wait, name, _timeout}, _from, %{status: status} = state)
      when status in [:merged, :closed] do
    {:reply, {:ok, closed_outcome(register(state, name))}, state}
  end

  # Merging is checked before the done-is-read-only rule: a closed one can still
  # be marked merged by hand, and a merged one learns when it reaches GitHub.
  def handle_call({:merged, commit, mode}, _from, state) do
    cond do
      state.merged && state.merged.pushed ->
        {:reply, {:ok, state.merged}, state}

      mode == :auto and (state.status == :closed or state.commits == []) ->
        {:reply, {:error, :not_merged}, state}

      true ->
        case find_merge(state, commit) do
          {:ok, info} when info == state.merged ->
            {:reply, {:ok, info}, state}

          {:ok, info} ->
            newly? = state.status != :merged or state.merged == nil

            state = %{
              state
              | status: :merged,
                merged: info,
                done_at: state.done_at || DateTime.utc_now()
            }

            state = if newly?, do: tell_closed(state), else: state
            {:reply, {:ok, info}, changed(state)}

          {:error, message} ->
            {:reply, {:error, message}, state}
        end
    end
  end

  def handle_call(:close, _from, %{status: status} = state) when status in [:merged, :closed] do
    {:reply, {:ok, status}, state}
  end

  def handle_call(msg, _from, %{status: status} = state)
      when status in [:merged, :closed] and elem(msg, 0) in [:comment, :decide, :addressed] do
    {:reply, {:error, "This merge request is #{status}."}, state}
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
          seq: state.seq + 1,
          at: DateTime.utc_now()
        }

        state = %{
          state
          | comments: state.comments ++ [comment],
            next_id: state.next_id + 1,
            seq: state.seq + 1
        }

        {:reply, {:ok, comment}, changed(tell_waiters(state))}
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
        seq: state.seq + 1,
        at: DateTime.utc_now()
      }

      state = %{
        state
        | decisions: state.decisions ++ [decision],
          status: verdict,
          seq: state.seq + 1
      }

      state = changed(tell_waiters(state))
      {:reply, {:ok, decision}, state}
    end
  end

  def handle_call({:addressed, commit, note, by}, _from, state) do
    repo = git_repo(state)

    with {:ok, sha} <- Git.rev_parse(repo, commit),
         true <- Git.on_branch?(repo, sha, state.branch) || {:error, :not_on_branch} do
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
    name = blank_to_nil(name) || "agent"
    state = register(state, name)

    if news?(state, name) do
      {outcome, state} = tell(state, name)
      Gitastic.Store.put(saved(state))
      {:reply, {:ok, outcome}, state}
    else
      ref = Process.monitor(pid)
      timer = Process.send_after(self(), {:wait_timeout, ref}, timeout)
      {:noreply, changed(%{state | waiters: Map.put(state.waiters, ref, {from, timer, name})})}
    end
  end

  def handle_call(:close, _from, state) do
    approved? = match?(%{verdict: :approved}, List.last(state.decisions))
    status = if approved?, do: :merged, else: :closed
    state = %{state | status: status, done_at: DateTime.utc_now()}
    state = changed(tell_closed(state))
    {:reply, {:ok, status}, state}
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

  # Tells every waiting agent its news, moving each one's cursor past it.
  defp tell_waiters(state) do
    Enum.reduce(state.waiters, %{state | waiters: %{}}, fn {ref, {from, timer, name}}, state ->
      Process.cancel_timer(timer)
      Process.demonitor(ref, [:flush])
      {outcome, state} = tell(state, name)
      GenServer.reply(from, {:ok, outcome})
      state
    end)
  end

  defp news?(state, name), do: Map.get(state.cursors, name, 0) < state.seq

  # What `name` hasn't been told yet: the comments since its cursor, and the
  # latest decision since then, if any. Moves its cursor to now.
  defp tell(state, name) do
    cursor = Map.get(state.cursors, name, 0)
    decision = state.decisions |> Enum.filter(&(&1.seq > cursor)) |> List.last()

    outcome = %{
      branch: state.branch,
      status: state.status,
      kind: if(decision, do: :decision, else: :comment),
      decision: decision,
      comments: Enum.filter(state.comments, &(&1.seq > cursor))
    }

    {outcome, %{state | cursors: Map.put(state.cursors, name, state.seq)}}
  end

  defp tell_closed(state) do
    for {ref, {from, timer, _name}} <- state.waiters do
      Process.cancel_timer(timer)
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:ok, closed_outcome(state)})
    end

    %{state | waiters: %{}}
  end

  defp closed_outcome(state) do
    %{
      branch: state.branch,
      status: state.status,
      kind: :closed,
      merged: state.merged,
      decision: nil,
      comments: []
    }
  end

  # Where the branch went into main: the given commit, or the one git finds on
  # local main, else on origin/main. `pushed` is whether origin/main has it.
  defp find_merge(state, commit) do
    repo = git_repo(state)
    remote = if match?({:ok, _}, Git.rev_parse(repo, "origin/main")), do: "origin/main"

    sha =
      cond do
        commit ->
          case Git.rev_parse(repo, commit) do
            {:ok, sha} -> sha
            {:error, _} -> nil
          end

        Git.ancestor?(repo, state.head, "main") ->
          Git.merge_commit(repo, "main", state.head)

        remote && Git.ancestor?(repo, state.head, remote) ->
          Git.merge_commit(repo, remote, state.head)

        true ->
          nil
      end

    with sha when is_binary(sha) <- sha,
         {:ok, info} <- Git.commit_info(repo, sha) do
      {:ok, Map.put(info, :pushed, remote != nil and Git.ancestor?(repo, sha, remote))}
    else
      _ ->
        {:error,
         if(commit, do: "#{commit} is not a commit.", else: "#{state.branch} is not on main yet.")}
    end
  end

  # A merge request saved before comments and decisions were numbered: number
  # them in the order they happened, and start each agent where the old rule
  # left it (told everything, or, while a decision is unanswered, that round).
  defp number_events(%{seq: _} = saved), do: saved

  defp number_events(saved) do
    events =
      (Enum.map(saved.comments, &{:comment, &1}) ++ Enum.map(saved.decisions, &{:decision, &1}))
      |> Enum.sort_by(&elem(&1, 1).at, DateTime)
      |> Enum.with_index(1)

    numbered = fn type -> for {{^type, e}, n} <- events, do: Map.put(e, :seq, n) end
    decisions = numbered.(:decision)
    seq = length(events)

    cursor =
      if saved.status in [:approved, :needs_work] do
        case Enum.take(decisions, -2) do
          [previous, _last] -> previous.seq
          _ -> 0
        end
      else
        seq
      end

    Map.merge(saved, %{
      comments: numbered.(:comment),
      decisions: decisions,
      seq: seq,
      cursors: Map.new(saved.agents, &{&1, cursor})
    })
  end

  # Recomputes the commits and the diff of the branch from git.
  defp refresh(state) do
    repo = git_repo(state)
    {:ok, head} = Git.rev_parse(repo, state.branch)

    merge_base =
      case Git.merge_base(repo, state.base, state.branch) do
        {:ok, sha} -> sha
        {:error, _} -> nil
      end

    commits =
      case Git.commits(repo, state.base, state.branch) do
        {:ok, commits} -> commits
        {:error, _} -> []
      end

    files =
      case Git.branch_diff(repo, state.base, state.branch) do
        {:ok, files} -> files
        {:error, _} -> []
      end

    %{state | head: head, merge_base: merge_base, commits: commits, files: files}
  end

  # What is written to disk: everything but the waiting agents.
  defp saved(state), do: state |> Map.from_struct() |> Map.delete(:waiters)

  defp changed(state) do
    Gitastic.Store.put(saved(state))
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
