defmodule Merge.MergeRequest do
  @moduledoc """
  One process per merge request, registered by branch. It holds everything
  about the merge request: the branch and base, title, body, who opened it, the
  comments, the decisions, what was addressed, the commits and the current diff,
  how the author says the files group (`groups`, see `Merge.Groups`), and the
  agents waiting to hear a decision. Every change is also written to
  disk (`Merge.Store`), and `restore_all/0` brings them back after a restart;
  waiting agents are not kept, their `wait` asks again.

  The review goes in rounds. A comment belongs to the round it was written in
  (the number of decisions before it); a decision closes its round; `addressed/4`
  answers the last decision with a commit and a note, recomputes the diff and
  opens the next round.

  Agents hear every comment and every decision. Each one gets the next number
  (`seq`), and each agent has a cursor: the last number it was told. `wait/3`
  answers at once with whatever is past the agent's cursor, or blocks until
  there is some, so nothing said while an agent re-arms its wait is missed.

  The branch is watched (`check_branch/1`, every minute from `Merge.Watcher`):
  new commits refresh the diff by themselves; a branch that was rewritten
  (its reviewed head no longer in it) or deleted is flagged in `branch_state`.
  Each new head, and each new tip of main, gets a trial merge into main
  (`merge_check`): clean, or the files that conflict. When it starts to
  conflict (or conflicts in other files), the agents are told, as an event in
  `conflicts`. These fields are read with `Map.get`, so merge requests from
  before them keep working.

  Merging is read from git: once the branch head is on local `main` the merge
  request is `:merged`, with the merge commit in `merged` (`pushed: false`
  until that commit is on `origin/main` too). `merged/2` marks it when the
  coordinator merges; `Merge.Watcher` calls `check_merged/1` every minute.

  The status says whose turn it is: `:open` (Needs review) is the reviewer's,
  `:in_progress` the author's. A rejection sets `:in_progress`, and so does
  `working/3`, when the author takes it back on their own (a new direction),
  with a note; `addressed/4` and opening the branch again hand it back as
  `:open`. Each `working` is told to the other agents like a comment.

  Closing doesn't end the process: the merge request is done, `:merged` when its
  last decision was an approval and `:closed` otherwise, and stays to look back
  at, read-only, with the diff as it was, until the server stops or the branch
  is opened again.

  Every change is broadcast on `topic(branch)` as `{:merge_request, mr}`, and
  `"merge_requests"` hears `:merge_requests_changed` when one opens, changes or closes.
  """

  use GenServer, restart: :temporary

  alias Merge.{Events, Git}

  @list_topic "merge_requests"

  # How long a caller waits for a reading of the branch it asked for: a
  # command (open, addressed, merged), and the watcher's look each minute.
  @settle_ms 60_000
  @look_ms 20_000

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
    :merge_check,
    :groups,
    :body_updated_at,
    :own_base,
    conflicts: [],
    branch_state: :ok,
    status: :open,
    agents: [],
    comments: [],
    decisions: [],
    addressed: [],
    working: [],
    commits: [],
    files: [],
    waiters: %{},
    next_id: 1,
    seq: 0,
    cursors: %{},
    # The waiting names the pages were last told (not saved).
    waiting_shown: [],
    # The reading of the branch from git that is under way (not saved): see `read/3`.
    job: nil
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
  The line the branch's own commits and diff are taken against: its base, or
  local main for an `origin/main` base (`Merge.Git.own_base/3`), as it was at
  the last look at the branch.
  """
  def own_base(mr), do: Map.get(mr, :own_base) || mr.base

  @doc "True for a commit that merged the base into the branch (`merge_of` is set)."
  def base_merge?(commit), do: Map.get(commit, :merge_of) != nil

  @doc "The branch's commits without the merges of the base into it."
  def own_commits(mr), do: Enum.reject(mr.commits, &base_merge?/1)

  @doc """
  Opens a merge request for `attrs.branch` in `attrs.repo`, or, when one is
  already open for the branch, registers the opener on it (and takes its
  `groups`, when it brings some), and a body it brings replaces the old one
  in place (see `update_body/3`). A done one for the branch makes way for the
  new one. Returns `{:ok, mr, :opened | :existing | :body_updated}`.
  """
  def open(attrs) do
    attrs = Map.new(attrs)
    branch = Map.fetch!(attrs, :branch)

    case lookup(branch) do
      {:ok, pid} ->
        case GenServer.call(pid, {:register, attrs[:opened_by], groups(attrs), attrs[:body]}) do
          :ok -> {:ok, get!(branch), :existing}
          :body_updated -> {:ok, get!(branch), :body_updated}
          :done -> open(attrs)
        end

      :error ->
        # Kept on disk and still in review, but its process is gone (a code
        # load can stop it): it comes back from its file first, so opening
        # the branch again never writes a new one over its comments.
        with %{status: status} = stored when status not in [:merged, :closed] <-
               Merge.Store.get(branch),
             {:ok, _pid} <-
               DynamicSupervisor.start_child(
                 Merge.MergeRequests,
                 {__MODULE__, {:restore, stored}}
               ) do
          open(attrs)
        else
          {:error, {:already_started, _pid}} -> open(attrs)
          _ -> open_new(attrs, branch)
        end
    end
  end

  # The branch and its base are looked up here, by whoever opens it: the merge
  # request's own process never runs git (see `read/3`).
  defp open_new(attrs, branch) do
    repo = Path.expand(attrs[:repo] || File.cwd!())
    base = blank_to_nil(attrs[:base]) || Git.default_base(repo)

    with {:ok, _} <- Git.rev_parse(repo, base),
         {:ok, head} <- Git.rev_parse(repo, branch) do
      attrs =
        Map.merge(attrs, %{repo: repo, base: base, head: head, git_dir: Git.common_dir(repo)})

      case DynamicSupervisor.start_child(Merge.MergeRequests, {__MODULE__, attrs}) do
        {:ok, _pid} ->
          # Answers once the commits and the diff are read, or as it is by then.
          settle(branch)
          {:ok, get!(branch), :opened}

        {:error, {:already_started, _pid}} ->
          open(attrs)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Waits until the reading of the branch that is under way is in (at most a
  minute). The merge request answers everything else meanwhile.
  """
  def settle(branch), do: call(branch, :settled, @settle_ms)

  def start_link({:restore, state}) do
    GenServer.start_link(__MODULE__, {:restore, state}, name: via(state.branch))
  end

  def start_link(attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(attrs.branch))
  end

  @doc "Starts a process for every stored merge request that isn't running. Returns how many."
  def restore_all do
    Merge.Store.all()
    |> Enum.count(fn state ->
      match?(
        {:ok, _},
        DynamicSupervisor.start_child(Merge.MergeRequests, {__MODULE__, {:restore, state}})
      )
    end)
  end

  @doc """
  Starts the stored merge requests that aren't running: one whose process
  died (a code reload can stop them all at once) comes back from its file.
  Until then it is still read as it was (`Merge.Board`).
  Reads only the files of the missing ones. Returns how many it started.
  """
  def restore_missing do
    running = MapSet.new(Registry.select(Merge.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]))
    stored = Merge.Store.branches()

    # One still on the board with no process and no file can't come back.
    for {branch, _} <- Merge.Board.summaries(),
        not MapSet.member?(running, branch),
        branch not in stored,
        do: Merge.Board.delete(branch)

    stored
    |> Enum.reject(&MapSet.member?(running, &1))
    |> Enum.count(fn branch ->
      with %{branch: ^branch} = state <- Merge.Store.get(branch),
           {:ok, _} <-
             DynamicSupervisor.start_child(Merge.MergeRequests, {__MODULE__, {:restore, state}}) do
        true
      else
        _ -> false
      end
    end)
  end

  @doc """
  Every merge request: the open ones oldest first, then the done ones, latest
  first. Each comes without its diff: `files` is empty and `file_count/1` says
  how many there are, so a list of two hundred is a megabyte to hand over, not
  fifty. `get/1` has the diff.
  """
  def list do
    listed = Merge.Board.summaries()

    # One whose process hasn't published yet (it started before the board
    # did) is asked once; its answer puts it on the board.
    asked =
      Merge.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.reject(&is_map_key(listed, &1))
      |> Enum.flat_map(fn branch ->
        case call(branch, :summary) do
          {:ok, mr} -> [mr]
          :error -> []
        end
      end)

    (Map.values(listed) ++ asked)
    |> Enum.split_with(&(not done?(&1)))
    |> then(fn {open, done} ->
      Enum.sort_by(open, & &1.opened_at, DateTime) ++
        Enum.sort_by(done, & &1.done_at, {:desc, DateTime})
    end)
  end

  @doc """
  The merge request for a branch, as its process last published it
  (`Merge.Board`): read without asking the process, so it answers at once
  whatever the process is doing. `waiting` names the agents blocked in `wait/3`.
  """
  def get(branch) do
    case Merge.Board.get(branch) do
      nil -> call(branch, :get)
      mr -> {:ok, mr}
    end
  end

  @doc "How many files it changes, for one from `get/1` or from `list/0`."
  def file_count(mr), do: Map.get(mr, :file_count) || length(mr.files)

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
  An agent's answer to comment `id`, shown under it. It sits on the same line
  as the comment it answers, the other agents hear it, and its author doesn't.
  """
  def reply(branch, id, body, by \\ nil), do: call(branch, {:reply, id, body, by})

  @doc "The agents that have been told about `comment`, other than its author."
  def seen_by(mr, comment) do
    for {name, cursor} <- mr.cursors, cursor >= comment.seq, name != comment.author, do: name
  end

  @doc """
  Approves (`:approved`) or rejects (`:needs_work`) the merge request, closing
  the round and telling every waiting agent. A rejection needs a comment, or a
  comment already written in this round.
  """
  def decide(branch, verdict, body \\ "", by \\ "reviewer")
      when verdict in [:approved, :needs_work] do
    call(branch, {:decide, verdict, String.trim(body || ""), by})
  end

  @doc """
  The author takes it back: the merge request is In progress, with `note`
  (what they are doing) shown under the badge, until `addressed/4` or the
  branch is opened again. The other agents hear it.
  """
  def working(branch, note \\ nil, by \\ nil), do: call(branch, {:working, note, by})

  @doc """
  The note of the `working/3` that put it In progress, or nil (not in
  progress, or sent back by a rejection since).
  """
  def working_note(%{status: :in_progress} = mr) do
    last_decision = mr.decisions |> List.last() |> then(&((&1 && &1.seq) || 0))

    case mr |> Map.get(:working, []) |> List.last() do
      %{seq: seq} = w when seq > last_decision -> w
      _ -> nil
    end
  end

  def working_note(_mr), do: nil

  @doc """
  Replaces the body of an open merge request in place, keeping the comments,
  the decisions, the commits and when it was opened; `body_updated_at` says
  when, and a `groups` block in it replaces how the files group. Emits
  `body-updated`. Answers `{:ok, :updated | :unchanged}`.
  """
  def update_body(branch, body, by \\ nil), do: call(branch, {:body, body, by})

  @doc """
  Records that `commit` addresses the last decision, recomputes the diff and
  starts a new round. `groups` (or a `groups` block in the note) replaces how
  the files group.
  """
  def addressed(branch, commit, note \\ nil, by \\ nil, groups \\ nil) do
    # The commit is looked up here, by the caller, not in the process.
    with {:ok, mr} <- get(branch),
         false <- done?(mr),
         repo = git_repo(mr),
         {:ok, sha} <- Git.rev_parse(repo, commit),
         true <- Git.on_branch?(repo, sha, mr.branch) || {:error, :not_on_branch} do
      call(branch, {:addressed, sha, note, by, groups}, @settle_ms)
    else
      # Done: the process says so, in its own words.
      true -> call(branch, {:addressed, commit, note, by, groups})
      {:error, :not_on_branch} -> {:error, "#{commit} is not on #{branch}."}
      {:error, message} -> {:error, message}
      :error -> :error
    end
  end

  @doc """
  Waits for news for the agent `name`: a comment or a decision it hasn't been
  told yet, the branch starting to conflict with main, or the merge request
  closing. Answers at once when there is some; otherwise blocks until there is,
  or `timeout` ms. Answers `{:ok, outcome}` (`kind` is `:comment`, `:decision`,
  `:conflicts` or `:closed`; `conflicts` is the latest conflict news or nil) or
  `{:ok, :timeout}`.
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
  def merged(branch, commit \\ nil), do: call(branch, {:merged, commit, :manual}, @settle_ms)

  @doc "Looks at the branch again: new commits, a rewrite or a deletion, and whether it merges cleanly."
  def check_branch(branch), do: call(branch, :check_branch, @look_ms)

  @doc "Marks it merged if git says it is, and notes when the merge reaches origin/main."
  def check_merged(branch), do: call(branch, {:merged, nil, :auto}, @look_ms)

  @doc "Marks it merged (when approved) or closed, and tells the waiting agents. It stays, read-only."
  def close(branch), do: call(branch, :close)

  defp call(branch, msg, timeout \\ 5_000) do
    case lookup(branch) do
      {:ok, pid} -> GenServer.call(pid, msg, timeout)
      :error -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp lookup(branch) do
    case Registry.lookup(Merge.Registry, branch) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via(branch), do: {:via, Registry, {Merge.Registry, branch}}

  ## Server

  @impl true
  def init({:restore, saved}) do
    # Fields added since it was saved take their defaults.
    saved = saved |> Map.put(:waiters, %{}) |> number_events()
    # Sent back for work was `:needs_work` before In progress.
    saved = if saved.status == :needs_work, do: %{saved | status: :in_progress}, else: saved
    state = struct(__MODULE__, saved)
    publish(state)
    {:ok, state}
  end

  # No git here: `open_new/2` looked up the base and the head. The commits,
  # the diff and the trial merge are read behind it (`read/3`); "opened" is
  # said once they are in.
  def init(attrs) do
    opened_by = blank_to_nil(attrs[:opened_by]) || "agent"
    {body, groups} = Merge.Body.split_groups(attrs[:body])

    state =
      %__MODULE__{
        branch: attrs.branch,
        base: attrs.base,
        repo: attrs.repo,
        title: blank_to_nil(attrs[:title]) || attrs.branch,
        body: body,
        groups: blank_to_nil(attrs[:groups]) || groups,
        opened_by: opened_by,
        opened_at: DateTime.utc_now(),
        agents: [opened_by],
        git_dir: attrs[:git_dir],
        head: attrs.head
      }
      |> read(:opened)

    Merge.Store.put(saved(state))
    publish(state)
    broadcast_list()
    {:ok, state}
  end

  @impl true
  # Asked only while it isn't on the board yet; the answer puts it there.
  def handle_call(:get, _from, state) do
    publish(state)
    {:reply, {:ok, public(state)}, state}
  end

  def handle_call(:summary, _from, state) do
    publish(state)
    {:reply, {:ok, summary(state)}, state}
  end

  # A done merge request steps aside for a new one on the same branch: it
  # unregisters itself before it stops, so the branch is free at once.
  def handle_call({:register, _name, _groups, _body}, _from, %{status: status} = state)
      when status in [:merged, :closed] do
    Registry.unregister(Merge.Registry, state.branch)
    Merge.Board.delete(state.branch)
    {:stop, :normal, :done, state}
  end

  # Opening it again hands it back for review.
  def handle_call({:register, name, groups, body}, _from, state) do
    state = register(state, name)

    {state, groups} =
      if state.status == :in_progress,
        do: {%{state | status: :open}, groups || state.groups},
        else: {state, groups}

    state = if groups, do: %{state | groups: groups}, else: state

    case put_body(state, body, name) do
      {:updated, state} ->
        {:reply, :body_updated, changed(state)}

      {:unchanged, state} when groups != nil ->
        {:reply, :ok, changed(state)}

      {:unchanged, state} ->
        Merge.Store.put(saved(state))
        publish(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:wait, name, _timeout}, _from, %{status: status} = state)
      when status in [:merged, :closed] do
    {:reply, {:ok, closed_outcome(register(state, name))}, state}
  end

  # Merging is checked before the done-is-read-only rule: a closed one can still
  # be marked merged by hand, and a merged one learns when it reaches GitHub.
  def handle_call({:merged, commit, mode}, from, state) do
    cond do
      state.merged && state.merged.pushed ->
        {:reply, {:ok, state.merged}, state}

      mode == :auto and (state.status == :closed or state.commits == []) ->
        {:reply, {:error, :not_merged}, state}

      true ->
        # Git finds the merge behind the process; the caller hears then.
        me = self()
        snapshot = Map.take(state, [:repo, :git_dir, :head, :branch])

        spawn(fn ->
          found =
            try do
              find_merge(snapshot, commit)
            catch
              _, _ -> {:error, "#{snapshot.branch} could not be read."}
            end

          send(me, {:found_merge, from, found})
        end)

        {:noreply, state}
    end
  end

  def handle_call(:check_branch, _from, %{status: status} = state)
      when status in [:merged, :closed],
      do: {:reply, :ok, state}

  def handle_call(:check_branch, from, state) do
    {:noreply, read(state, :look, {from, :ok})}
  end

  def handle_call(:settled, from, state) do
    case Map.get(state, :job) do
      nil -> {:reply, :ok, state}
      job -> {:noreply, %{state | job: %{job | told: [{from, :ok} | job.told]}}}
    end
  end

  def handle_call(:close, _from, %{status: status} = state) when status in [:merged, :closed] do
    {:reply, {:ok, status}, state}
  end

  def handle_call(msg, _from, %{status: status} = state)
      when status in [:merged, :closed] and
             elem(msg, 0) in [:comment, :reply, :decide, :addressed, :working, :body] do
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

        Events.emit("comment", state.branch, "#{where(comment)} #{comment.author}: #{body}")
        {:reply, {:ok, comment}, changed(tell_waiters(state))}
    end
  end

  def handle_call({:reply, id, body, by}, _from, state) do
    parent = Enum.find(state.comments, &(&1.id == id))
    by = blank_to_nil(by) || "agent"

    cond do
      parent == nil ->
        {:reply, {:error, "There is no comment #{id}."}, state}

      blank_to_nil(body) == nil ->
        {:reply, {:error, "A reply needs some text."}, state}

      true ->
        reply =
          parent
          |> Map.take([:path, :line, :side, :commit])
          |> Map.merge(%{
            id: state.next_id,
            body: body,
            author: by,
            reply_to: id,
            round: length(state.decisions),
            seq: state.seq + 1,
            at: DateTime.utc_now()
          })

        # The author already knows what it wrote: move its cursor past it,
        # unless it had news still to hear.
        state = register(state, by)

        cursors =
          if Map.get(state.cursors, by, 0) == state.seq,
            do: Map.put(state.cursors, by, reply.seq),
            else: state.cursors

        state = %{
          state
          | comments: state.comments ++ [reply],
            next_id: state.next_id + 1,
            seq: reply.seq,
            cursors: cursors
        }

        Events.emit("reply", state.branch, "to ##{id} #{by}: #{body}")
        {:reply, {:ok, reply}, changed(tell_waiters(state))}
    end
  end

  def handle_call({:decide, verdict, body, by}, _from, state) do
    round = length(state.decisions)
    # An agent's replies don't say what needs work.
    round_comments =
      Enum.filter(state.comments, &(&1.round == round and Map.get(&1, :reply_to) == nil))

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
          status: if(verdict == :approved, do: :approved, else: :in_progress),
          seq: state.seq + 1
      }

      event = if verdict == :approved, do: "approved", else: "needs-work"
      by = if by, do: "#{by}: ", else: ""
      Events.emit(event, state.branch, "at #{Events.short(state.head)} #{by}#{body}")

      state = changed(tell_waiters(state))
      # Auto Merge looks at it in the watcher, once this call is done.
      if verdict == :approved, do: Merge.Watcher.auto_merge(state.branch)
      {:reply, {:ok, decision}, state}
    end
  end

  def handle_call({:working, note, by}, _from, state) do
    by = blank_to_nil(by) || state.opened_by
    entry = %{note: blank_to_nil(note), by: by, seq: state.seq + 1, at: DateTime.utc_now()}

    # The author knows: its cursor moves past it, unless it had news still to hear.
    state = register(state, by)

    cursors =
      if Map.get(state.cursors, by, 0) == state.seq,
        do: Map.put(state.cursors, by, entry.seq),
        else: state.cursors

    state = %{
      state
      | status: :in_progress,
        working: Map.get(state, :working, []) ++ [entry],
        seq: entry.seq,
        cursors: cursors
    }

    note = if entry.note, do: ": #{entry.note}", else: ""
    Events.emit("working", state.branch, "#{by}#{note}")
    {:reply, {:ok, entry}, changed(tell_waiters(state))}
  end

  def handle_call({:body, body, by}, _from, state) do
    if blank_to_nil(body) == nil do
      {:reply, {:error, "A body needs some text."}, state}
    else
      case put_body(state, body, by) do
        {:updated, state} -> {:reply, {:ok, :updated}, changed(state)}
        {:unchanged, state} -> {:reply, {:ok, :unchanged}, state}
      end
    end
  end

  # `sha` is on the branch: `addressed/5` looked. The caller hears once the
  # branch is read again.
  def handle_call({:addressed, sha, note, by, groups}, from, state) do
    {note, note_groups} = Merge.Body.split_groups(note)
    groups = blank_to_nil(groups) || note_groups || state.groups

    entry = %{
      sha: sha,
      short: String.slice(sha, 0, 7),
      note: blank_to_nil(note),
      by: blank_to_nil(by) || state.opened_by,
      # The round it answers: the last decision's.
      round: length(state.decisions) - 1,
      at: DateTime.utc_now()
    }

    note = if entry.note, do: ": #{entry.note}", else: ""
    Events.emit("addressed", state.branch, "#{entry.short} #{entry.by}#{note}")

    state =
      %{state | addressed: state.addressed ++ [entry], status: :open, groups: groups}
      |> read(:whole, {from, {:ok, entry}})

    {:noreply, changed(state)}
  end

  def handle_call({:wait, name, timeout}, {pid, _} = from, state) do
    name = blank_to_nil(name) || "agent"
    before = state
    state = register(state, name)

    if news?(state, name) do
      {outcome, state} = tell(state, name)
      Merge.Store.put(saved(state))
      publish(state)
      {:reply, {:ok, outcome}, state}
    else
      ref = Process.monitor(pid)
      timer = Process.send_after(self(), {:wait_timeout, ref}, timeout)
      new_agent? = state.agents != before.agents
      state = %{state | waiters: Map.put(state.waiters, ref, {from, timer, name})}
      # A wait asked again every minute is no change: only a new name is.
      {:noreply, if(new_agent?, do: changed(state), else: tell_waiting(state))}
    end
  end

  def handle_call(:close, _from, state) do
    approved? = match?(%{verdict: :approved}, List.last(state.decisions))
    status = if approved?, do: :merged, else: :closed
    state = %{state | status: status, done_at: DateTime.utc_now()}
    detail = if approved?, do: "approved, kept as merged: #{state.title}", else: state.title
    Events.emit("closed", state.branch, detail)
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

  # The branch as git has it now (`read/3`).
  def handle_info({:reading, pid, reading}, state) do
    case Map.get(state, :job) do
      %{pid: ^pid} = job -> {:noreply, take_reading(%{state | job: nil}, job, reading)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:found_merge, from, found}, state) do
    {reply, state} = note_merge(state, found)
    GenServer.reply(from, reply)
    {:noreply, state}
  end

  # The reading died before it answered (a code load can stop it): whoever
  # waits is let go, and it is read again at the next look.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job: %{ref: ref} = job} = state)
      when reason != :normal do
    for {from, reply} <- job.told, do: GenServer.reply(from, reply)
    state = %{state | job: nil}
    state = if job.kind == :look, do: state, else: changed(state)
    {:noreply, read_next(state, job)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.waiters, ref) do
      {{_from, timer, _name}, waiters} ->
        Process.cancel_timer(timer)
        {:noreply, tell_waiting(%{state | waiters: waiters})}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: broadcast_list()

  ## Helpers

  # A new body (and its `groups` block) in place of the old; nothing else
  # changes. A blank or identical one is no change.
  defp put_body(state, body, by) do
    {body, groups} = Merge.Body.split_groups(body)

    if blank_to_nil(body) == nil and groups == nil do
      {:unchanged, state}
    else
      body = body || ""
      new = %{state | body: body, groups: groups || state.groups}

      if new.body == state.body and new.groups == state.groups do
        {:unchanged, state}
      else
        new = Map.put(new, :body_updated_at, DateTime.utc_now())
        Events.emit("body-updated", state.branch, "by #{blank_to_nil(by) || state.opened_by}")
        {:updated, new}
      end
    end
  end

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

  # What `name` hasn't been told yet: the comments since its cursor, the
  # latest decision since then, and the latest conflicts, if any. Moves its
  # cursor to now.
  defp tell(state, name) do
    cursor = Map.get(state.cursors, name, 0)
    decision = state.decisions |> Enum.filter(&(&1.seq > cursor)) |> List.last()
    comments = Enum.filter(state.comments, &(&1.seq > cursor))
    conflicts = state |> Map.get(:conflicts, []) |> Enum.filter(&(&1.seq > cursor)) |> List.last()
    working = state |> Map.get(:working, []) |> Enum.filter(&(&1.seq > cursor)) |> List.last()

    kind =
      cond do
        decision -> :decision
        comments != [] -> :comment
        working -> :working
        conflicts -> :conflicts
        true -> :comment
      end

    outcome = %{
      branch: state.branch,
      status: state.status,
      kind: kind,
      decision: decision,
      comments: comments,
      conflicts: conflicts,
      working: working
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
      comments: [],
      conflicts: nil,
      working: nil
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

  # Git is never run in this process. A reading of the branch is taken behind
  # it, by a process of its own, and comes back as a message
  # (`{:reading, pid, reading}`), so the merge request answers comments,
  # decisions and waits while git works, however long that is.
  #
  # `kind` is `:look` (the watcher's: commits and diff only if the head moved),
  # `:whole` (an `addressed`: all of it again) or `:opened` (the first).
  # `tell` is `{from, reply}`: who hears, and what, once it is in. One reading
  # at a time: a look asked meanwhile hears with the one under way; a whole
  # one asked meanwhile is taken after it.
  defp read(state, kind, tell \\ nil) do
    case Map.get(state, :job) do
      nil ->
        me = self()
        snapshot = Map.take(state, [:repo, :git_dir, :branch, :base, :head, :merge_check])
        whole? = kind != :look

        {pid, ref} =
          spawn_monitor(fn -> send(me, {:reading, self(), reading(snapshot, whole?)}) end)

        job = %{pid: pid, ref: ref, kind: kind, told: List.wrap(tell), next: nil}
        Map.put(state, :job, job)

      %{} = job when kind == :look ->
        %{state | job: %{job | told: List.wrap(tell) ++ job.told}}

      %{} = job ->
        next = List.wrap(tell) ++ (job.next || [])
        %{state | job: %{job | next: next}}
    end
  end

  # A whole reading asked for while one was under way is taken now.
  defp read_next(state, %{next: nil}), do: state

  defp read_next(state, %{next: told}) do
    state = read(state, :whole)
    %{state | job: %{state.job | told: told}}
  end

  # What git says of the branch now, worked out away from the process: `:gone`,
  # or its head, the commits and diff (when the head moved, or all is asked),
  # whether it was rewritten, and the trial merge into main (`:same` when
  # neither side moved since the last).
  defp reading(snapshot, whole?) do
    repo = git_repo(snapshot)

    case Git.rev_parse(repo, snapshot.branch) do
      {:error, _} ->
        :gone

      {:ok, head} ->
        moved? = head != snapshot.head

        %{
          head: head,
          moved?: moved?,
          rewritten?: moved? and not Git.ancestor?(repo, snapshot.head, head),
          fresh: if(moved? or whole?, do: fresh(repo, snapshot.base, head)),
          merge: trial_merge(repo, snapshot.base, head, snapshot.merge_check)
        }
    end
  end

  # The commits and the diff of the branch at `head`, against the line it
  # merges into (`Git.own_base/3`), so all of it is the branch's own.
  defp fresh(repo, base, head) do
    own = Git.own_base(repo, base, head)

    merge_base =
      case Git.merge_base(repo, own, head) do
        {:ok, sha} -> sha
        {:error, _} -> nil
      end

    commits =
      case Git.commits(repo, own, head) do
        {:ok, commits} -> Enum.map(commits, &mark_base_merge(repo, own, &1))
        {:error, _} -> []
      end

    files =
      case Git.branch_diff(repo, own, head) do
        {:ok, files} -> files
        {:error, _} -> []
      end

    %{head: head, merge_base: merge_base, commits: commits, files: files, own_base: own}
  end

  # A trial merge of the branch into main (local main, where merges happen),
  # done again only when the branch head or main's tip has moved.
  defp trial_merge(repo, base, head, last) do
    target = if match?({:ok, _}, Git.rev_parse(repo, "main")), do: "main", else: base

    with {:ok, target_sha} <- Git.rev_parse(repo, target),
         false <- match?(%{target: ^target_sha, head: ^head}, last),
         result when result == :clean or elem(result, 0) == :conflicts <-
           Git.merge_check(repo, target_sha, head) do
      %{into: target, target: target_sha, head: head, result: result}
    else
      _ -> :same
    end
  end

  # A reading is in: the merge request takes it, says what it turned up (new
  # commits, a rewrite, a deletion, conflicts), tells whoever waited, and reads
  # again if a whole reading was asked for meanwhile.
  defp take_reading(state, job, reading) do
    whole? = job.kind != :look

    next =
      case reading do
        :gone ->
          # Gone: keep the last diff seen.
          Map.put(state, :branch_state, :gone)

        %{} ->
          branch_state =
            cond do
              whole? or not reading.moved? -> :ok
              reading.rewritten? -> {:rewritten, String.slice(state.head, 0, 7)}
              true -> :ok
            end

          state
          |> Map.merge(reading.fresh || %{})
          |> Map.put(:branch_state, branch_state)
          |> take_merge(reading.merge)
      end

    if job.kind == :opened do
      Events.emit(
        "opened",
        next.branch,
        "#{next.title} (#{length(own_commits(next))} commits) by #{next.opened_by}"
      )

      emit_changes(%{next | merge_check: nil}, next)
    else
      emit_changes(state, next)
    end

    next = if next.seq > state.seq, do: tell_waiters(next), else: next
    # A look that found nothing new says nothing.
    next = if whole? or next != state, do: changed(next), else: next
    for {from, reply} <- job.told, do: GenServer.reply(from, reply)
    read_next(next, job)
  end

  defp take_merge(state, :same), do: state

  defp take_merge(state, %{into: into, target: target_sha, result: result} = check) do
    state |> note_conflicts(result, into, target_sha) |> Map.put(:merge_check, check)
  end

  # What a search for the merge found (`find_merge/2`), as `merged/2` answers it.
  defp note_merge(state, found) do
    case found do
      {:ok, info} when info == state.merged ->
        {{:ok, info}, state}

      {:ok, info} ->
        newly? = state.status != :merged or state.merged == nil
        was_pushed? = match?(%{pushed: true}, state.merged)

        state = %{
          state
          | status: :merged,
            merged: info,
            done_at: state.done_at || DateTime.utc_now()
        }

        if newly?, do: Events.emit("merged", state.branch, merged_detail(info))

        if info.pushed and not was_pushed?,
          do: Events.emit("on-origin", state.branch, merged_detail(info))

        state = if newly?, do: tell_closed(state), else: state
        {{:ok, info}, changed(state)}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  # A merge whose second parent is on the base is a merge of the base into the
  # branch: it says which (`merge_of`, "main"), how many files the base brought
  # (`from_base`) and how many the author changed in it (`own_files`, the
  # conflicts resolved by hand, from `Git.remerge_diff/2`).
  defp mark_base_merge(repo, own, %{parents: [ours, theirs | _]} = commit) do
    if Git.ancestor?(repo, theirs, own) do
      from_base =
        case Git.paths_between(repo, ours, commit.sha) do
          {:ok, paths} -> length(paths)
          _ -> 0
        end

      own_files =
        case Git.remerge_diff(repo, commit.sha) do
          {:ok, files} -> length(files)
          _ -> 0
        end

      Map.merge(commit, %{
        merge_of: String.replace_prefix(own, "origin/", ""),
        from_base: from_base,
        own_files: own_files
      })
    else
      commit
    end
  end

  defp mark_base_merge(_repo, _own, commit), do: commit

  # Conflicts the agents haven't heard about become an event they're told:
  # when the branch starts conflicting, or conflicts in other files. Not once
  # it's merged or closed.
  defp note_conflicts(state, {:conflicts, files}, into, target_sha)
       when state.status not in [:merged, :closed] do
    case Map.get(state, :merge_check) do
      %{result: {:conflicts, ^files}} ->
        state

      _ ->
        event = %{
          seq: state.seq + 1,
          files: files,
          into: into,
          target: target_sha,
          head: state.head,
          at: DateTime.utc_now()
        }

        state
        |> Map.put(:conflicts, Map.get(state, :conflicts, []) ++ [event])
        |> Map.put(:seq, state.seq + 1)
    end
  end

  defp note_conflicts(state, _result, _into, _target_sha), do: state

  # The events a look at the branch turned up: new commits, a rewrite or a
  # deletion, and the trial merge starting or stopping to conflict.
  defp emit_changes(old, new) do
    branch = new.branch
    old_state = Map.get(old, :branch_state, :ok)
    new_state = Map.get(new, :branch_state, :ok)
    old_result = with %{result: r} <- Map.get(old, :merge_check), do: r
    new_result = with %{result: r} <- Map.get(new, :merge_check), do: r

    cond do
      new_state == :gone and old_state != :gone ->
        Events.emit("branch-gone", branch, "last seen at #{Events.short(old.head)}")

      match?({:rewritten, _}, new_state) and new.head != old.head ->
        Events.emit("rewritten", branch, "#{Events.short(old.head)} → #{Events.short(new.head)}")

      new.head != old.head ->
        seen = MapSet.new(old.commits, & &1.sha)
        fresh = Enum.reject(own_commits(new), &MapSet.member?(seen, &1.sha))
        latest = List.first(new.commits)
        subject = if latest, do: " #{latest.subject}", else: ""

        # Only merges of the base: nothing of the author's to count.
        detail =
          case {fresh, Enum.find(new.commits, &(base_merge?(&1) and &1.sha not in seen))} do
            {[], %{merge_of: base}} -> "#{base} merged in → #{Events.short(new.head)}"
            _ -> "#{length(fresh)} → #{Events.short(new.head)}#{subject}"
          end

        Events.emit("new-commits", branch, detail)

      true ->
        :ok
    end

    case {old_result, new_result} do
      {same, same} ->
        :ok

      {_, {:conflicts, files}} ->
        %{into: into, target: target} = new.merge_check
        detail = "into #{into} (#{Events.short(target)}): #{Enum.join(files, ", ")}"
        Events.emit("conflicts", branch, detail)

      {{:conflicts, _}, :clean} ->
        Events.emit("merges-cleanly", branch, "into #{new.merge_check.into}")

      _ ->
        :ok
    end
  end

  defp where(%{path: path, line: line, side: side}) when is_binary(path) and line != nil,
    do: "#{path}:#{line}#{if side == "old", do: " (old)", else: ""}"

  defp where(%{path: path}) when is_binary(path), do: path
  defp where(_comment), do: "general"

  defp merged_detail(info), do: "#{info.short} #{info.subject}"

  # What is written to disk: everything but the waiting agents.
  defp saved(state),
    do: state |> Map.from_struct() |> Map.drop([:waiters, :waiting_shown, :job])

  # On the board before anyone is told, so whoever hears reads the new state.
  defp publish(state), do: Merge.Board.put(state.branch, public(state), summary(state))

  defp summary(state),
    do: public(%{state | files: []}) |> Map.put(:file_count, length(state.files))

  defp changed(state) do
    Merge.Store.put(saved(state))
    publish(state)
    broadcast(state)
    Map.put(state, :waiting_shown, waiting(state))
  end

  # Who is waiting changed, and nothing else: the pages hear the names alone
  # (`{:waiting, names}`), nothing is written, and a wait that ran out and was
  # asked again (the same names as last told) says nothing at all.
  defp tell_waiting(state) do
    shown = Map.get(state, :waiting_shown, [])

    case waiting(state) do
      # Read with Map.get: a process from before the field has none.
      names when names == shown ->
        state

      names ->
        publish(state)
        Phoenix.PubSub.broadcast(Merge.PubSub, topic(state.branch), {:waiting, names})
        broadcast_list()
        Map.put(state, :waiting_shown, names)
    end
  end

  defp waiting(state),
    do: state.waiters |> Map.values() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Merge.PubSub,
      topic(state.branch),
      {:merge_request, public(state)}
    )

    broadcast_list()
  end

  defp broadcast_list do
    Phoenix.PubSub.broadcast(Merge.PubSub, @list_topic, :merge_requests_changed)
  end

  # `waiting` names the agents blocked in `wait/3` right now.
  defp public(state) do
    state
    |> Map.from_struct()
    |> Map.drop([:waiters, :waiting_shown, :job])
    |> Map.put(:waiting, waiting(state))
    # True while it is first read, or read again for an `addressed`: the page says so.
    |> Map.put(:reading, match?(%{kind: kind} when kind != :look, Map.get(state, :job)))
  end

  # The groups an open brings: `attrs.groups`, else a `groups` block in the body.
  defp groups(attrs) do
    blank_to_nil(attrs[:groups]) || elem(Merge.Body.split_groups(attrs[:body]), 1)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
