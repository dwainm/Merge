defmodule Merge.AutoMerge do
  @moduledoc """
  Merges an approved branch into main by itself, as a coordinator would. There
  is no switch: an approval means merge.

  An approved merge request's branch goes into the repo's local main, in the
  worktree that has main checked out: `git merge --no-ff <tip> -m "Merge
  <branch>"`, the commit a coordinator makes. Then it is marked merged as `mr
  merged` does (`Merge.MergeRequest.merged/2`), so `merged` comes first, then
  `auto-merged <branch> <sha>`, then `main-tip` and the checks, as after any
  change to main. Several approved ones go one at a time, oldest approval
  first, so each new tip of main is one clean step.

  It holds, and says why (`hold/1`, and `auto-merge-held <branch> <reason>`
  once per reason), when:

    * the approval came with a note, or the review holds a reviewer's comment
      nobody answered: an Approve that comes with a change request is a mis-tap
    * the base isn't main (a stacked request)
    * the branch is gone, or its tip moved after the approval by anything but
      a merge of main into it (a merge with nothing of its own in it, unless
      it resolved a conflict)
    * main isn't checked out anywhere, its worktree has uncommitted changes to
      tracked files, or a merge (rebase, cherry-pick, revert) is in progress there
    * main's checks or image build failed on its tip: no merge on a red main
    * the branch doesn't merge cleanly into main
    * the merge failed: it is aborted, main is as it was, and it isn't tried
      again until the branch or main moves

  Each hold is looked at again every round, so it merges once the hold is gone
  and the request is still approved. A coordinator's own `git merge` and `mr
  merged` work as before: a branch already on main is only marked merged.

  No process of its own: `Merge.Watcher` calls `run/1` when a merge request is
  approved and after each round, so one merge runs at a time (`run/1` also
  takes a lock, for any other caller). What holds each branch, and the merges
  that failed, are kept in memory: after a restart each hold is said once more,
  and a failed merge may be tried once more. `config :merge, auto_merge: false`
  (the tests, in test_helper.exs) turns it off.
  """

  alias Merge.{Checks, Drift, Events, Git, MergeRequest}

  def topic, do: "auto_merge"

  @doc "Whether it runs at all: always, but in the tests."
  def enabled?, do: Application.get_env(:merge, :auto_merge, true) != false

  ## Holds

  @doc "What holds each branch, `%{branch => %{reason, at}}`."
  def holds, do: :persistent_term.get({__MODULE__, :holds}, %{})

  @doc "Why it isn't merging `branch` (lowercase), or nil."
  def hold(branch) do
    with %{reason: reason} <- Map.get(holds(), branch), do: reason
  end

  @doc "What holds `branch`, `%{reason, at}`, or nil."
  def hold_entry(branch), do: Map.get(holds(), branch)

  # Said once per reason: a new reason for the branch is an event, the same one isn't.
  defp note_hold(branch, reason) do
    holds = holds()

    unless match?(%{reason: ^reason}, holds[branch]) do
      put_holds(Map.put(holds, branch, %{reason: reason, at: DateTime.utc_now()}))
      Events.emit("auto-merge-held", branch, reason)
      broadcast()
    end

    {:hold, reason}
  end

  defp drop_holds(branches) do
    holds = holds()
    kept = Map.drop(holds, branches)

    if map_size(kept) != map_size(holds) do
      put_holds(kept)
      broadcast()
    end
  end

  defp put_holds(holds), do: :persistent_term.put({__MODULE__, :holds}, holds)

  defp tried, do: :persistent_term.get({__MODULE__, :tried}, %{})

  defp put_tried(branch, entry) do
    tried = tried()
    new = if entry, do: Map.put(tried, branch, entry), else: Map.delete(tried, branch)
    if new != tried, do: :persistent_term.put({__MODULE__, :tried}, new)
  end

  ## Running

  @doc """
  Looks at the approved merge requests (or only `branch`'s), oldest approval
  first, and merges each one that nothing holds. Answers `:off` when turned
  off (the tests), else `[{branch, result}]` where a result is `{:merged,
  sha}`, `:already` (it was on main) or `{:hold, reason}`. Any error holds it.
  `opts` as for `judge/2`.
  """
  def run(branch \\ nil, opts \\ []) do
    if enabled?(),
      do: :global.trans({__MODULE__, :run}, fn -> run_on(branch, opts) end, [node()], :infinity),
      else: :off
  end

  defp run_on(branch, opts) do
    approved = Enum.filter(MergeRequest.list(), &(&1.status == :approved))

    # A hold is about an approved, open merge request; anything else forgets it.
    if branch == nil do
      keep = MapSet.new(approved, & &1.branch)
      drop_holds(holds() |> Map.keys() |> Enum.reject(&MapSet.member?(keep, &1)))
    end

    approved
    |> Enum.filter(&(branch == nil or &1.branch == branch))
    |> Enum.sort_by(&approved_at/1, DateTime)
    |> Enum.map(&{&1.branch, run_one(&1, opts)})
  end

  defp approved_at(mr) do
    case List.last(mr.decisions) do
      %{at: %DateTime{} = at} -> at
      _ -> mr.opened_at
    end
  end

  defp run_one(mr, opts) do
    case judge(mr, opts) do
      {:merge, plan} ->
        merge(plan)

      {:hold, reason} ->
        note_hold(mr.branch, reason)

      :already ->
        drop_holds([mr.branch])
        _ = MergeRequest.check_merged(mr.branch)
        :already
    end
  rescue
    e -> note_hold(mr.branch, "auto-merge error: " <> Exception.message(e))
  end

  @doc """
  What it would do with `mr` (as `Merge.MergeRequest.get/1` gives it):
  `{:merge, plan}`, `{:hold, reason}`, or `:already` when the branch is on
  main. Reads git and the checks, changes nothing. `opts` give main's checks
  (`:checks_on`, `:checks`, `:image`); by default they are read from the server.
  """
  def judge(mr, opts \\ []) do
    decision = List.last(mr.decisions)
    repo = MergeRequest.git_repo(mr)

    with :ok <- approval_ok(mr, decision),
         :ok <- base_ok(mr),
         {:ok, tip} <- tip(repo, mr.branch),
         {:ok, worktree, main} <- main_worktree(repo),
         :not_yet <- already(repo, tip, main),
         :ok <- moved_ok(repo, decision.head, tip, main),
         :ok <- main_green(main, opts),
         :ok <- merges_cleanly(repo, main, tip),
         :ok <- not_failed_before(mr.branch, tip, main) do
      {:merge, %{branch: mr.branch, repo: repo, worktree: worktree, tip: tip, main: main}}
    end
  end

  defp approval_ok(mr, decision) do
    cond do
      not match?(%{verdict: :approved}, decision) ->
        {:hold, "the last decision isn't an approval"}

      decision.body not in [nil, ""] ->
        {:hold, "the approval came with a note: merge it by hand"}

      (open = unanswered(mr, decision)) != [] ->
        ids = Enum.map_join(open, ", ", &"##{&1.id}")
        {:hold, "#{count(open, "comment")} not answered (#{ids})"}

      true ->
        :ok
    end
  end

  # The reviewer's comments from the approval's round on, with no reply.
  defp unanswered(mr, decision) do
    replied = MapSet.new(mr.comments, &Map.get(&1, :reply_to))

    Enum.filter(mr.comments, fn c ->
      Map.get(c, :reply_to) == nil and c.round >= decision.round and
        c.author not in mr.agents and not MapSet.member?(replied, c.id)
    end)
  end

  defp base_ok(%{base: base}) when base in ["main", "origin/main"], do: :ok
  defp base_ok(%{base: base}), do: {:hold, "stacked on #{base}, not main: merge it by hand"}

  defp tip(repo, branch) do
    case Git.rev_parse(repo, branch) do
      {:ok, tip} -> {:ok, tip}
      {:error, _} -> {:hold, "the branch is gone"}
    end
  end

  defp main_worktree(repo) do
    case Git.checked_out_in(repo, "main") do
      nil ->
        {:hold, "main isn't checked out in any worktree"}

      worktree ->
        cond do
          what = Git.in_progress(worktree) ->
            {:hold, "a #{in_progress_word(what)} is in progress in main's worktree"}

          Git.dirty?(worktree) ->
            {:hold, "main's worktree has uncommitted changes"}

          true ->
            case Git.rev_parse(worktree, "HEAD") do
              {:ok, main} -> {:ok, worktree, main}
              {:error, message} -> {:hold, message}
            end
        end
    end
  end

  defp in_progress_word(:cherry_pick), do: "cherry-pick"
  defp in_progress_word(what), do: Atom.to_string(what)

  defp already(repo, tip, main) do
    if Git.ancestor?(repo, tip, main), do: :already, else: :not_yet
  end

  # The tip is the approved head, or that head with only merges of main on top.
  defp moved_ok(_repo, head, head, _main), do: :ok

  defp moved_ok(repo, head, tip, main) do
    moved = {:hold, "the branch moved after the approval (#{short(head)} → #{short(tip)})"}

    with true <- is_binary(head) and Git.ancestor?(repo, head, tip),
         {:ok, line} <- Git.first_parent_line(repo, head, tip),
         true <- line != [] and Enum.all?(line, &merge_of_main?(repo, &1, main)) do
      :ok
    else
      _ -> moved
    end
  end

  defp merge_of_main?(repo, [sha, ours, theirs], main),
    do: Git.ancestor?(repo, theirs, main) and Git.plain_merge?(repo, sha, ours, theirs)

  defp merge_of_main?(_repo, _commit, _main), do: false

  # No merge on a red main: its checks, or its image build, failed on its tip.
  defp main_green(main, opts) do
    if Keyword.get_lazy(opts, :checks_on, &checks_on?/0) do
      checks = Keyword.get_lazy(opts, :checks, fn -> Checks.status(main) end)
      image = Keyword.get_lazy(opts, :image, fn -> Checks.image_status(main) end)

      cond do
        match?(%{ok: false}, checks) ->
          {:hold, "main's checks failed on #{short(main)}: waiting for a green main"}

        match?(%{ok: false}, image) ->
          {:hold, "main's image build failed on #{short(main)}: waiting for a green main"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp checks_on? do
    match?(pid when is_pid(pid), Process.whereis(Checks)) and Checks.enabled?()
  end

  defp merges_cleanly(repo, main, tip) do
    case Git.merge_check(repo, main, tip) do
      :clean -> :ok
      {:conflicts, files} -> {:hold, "conflicts with main: #{Enum.join(files, ", ")}"}
      {:error, message} -> {:hold, "the trial merge failed: #{message}"}
    end
  end

  # A merge that failed isn't tried again until the branch or main moves.
  defp not_failed_before(branch, tip, main) do
    case Map.get(tried(), branch) do
      %{tip: ^tip, main: ^main, reason: reason} -> {:hold, reason}
      _ -> :ok
    end
  end

  defp merge(%{branch: branch, worktree: worktree, tip: tip, main: main} = plan) do
    case Git.merge_no_ff(worktree, tip, "Merge #{branch}", main) do
      {:ok, sha} ->
        put_tried(branch, nil)
        drop_holds([branch])
        _ = MergeRequest.check_branch(branch)
        _ = MergeRequest.merged(branch, sha)
        Events.emit("auto-merged", branch, Events.short(sha))
        after_merge(plan)
        broadcast()
        {:merged, sha}

      {:error, output} ->
        as_was? =
          match?({:ok, ^main}, Git.rev_parse(worktree, "HEAD")) and not Git.dirty?(worktree) and
            Git.in_progress(worktree) == nil

        reason =
          if as_was?,
            do: "the merge failed, main is as it was: #{first_line(output)}",
            else: "the merge failed and main's worktree isn't as it was: look at it by hand"

        put_tried(branch, %{tip: tip, main: main, reason: reason})
        note_hold(branch, reason)
    end
  end

  # As after any change to main: the drift (and its `main-tip`) and the checks.
  defp after_merge(%{repo: repo}) do
    drift_repo = Drift.repo() || repo

    with %{main: main} <- Drift.refresh(drift_repo),
         pid when is_pid(pid) <- Process.whereis(Checks),
         do: Checks.want(drift_repo, main)
  end

  ## The page

  @doc "A reason, capitalised, for the page."
  def text(nil), do: nil
  def text(reason), do: String.capitalize(String.first(reason)) <> String.slice(reason, 1..-1//1)

  defp first_line(output) do
    output |> String.split("\n", trim: true) |> List.first() || "git said nothing"
  end

  defp short(nil), do: "?"
  defp short(sha), do: String.slice(sha, 0, 7)

  defp count([_], word), do: "1 #{word}"
  defp count(list, word), do: "#{length(list)} #{word}s"

  defp broadcast, do: Phoenix.PubSub.broadcast(Merge.PubSub, topic(), :auto_merge)
end
