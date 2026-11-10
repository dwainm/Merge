defmodule Merge.AutoMergeTest do
  # Auto Merge runs in the one watcher and looks at every merge request: these
  # tests turn it on, so none may run beside them.
  use ExUnit.Case, async: false

  alias Merge.{AutoMerge, Drift, Events, GitRepo, MergeRequest}

  setup do
    Application.put_env(:merge, :auto_merge, true)
    was_repo = Application.get_env(:merge, :repo)
    sync()
    :persistent_term.erase({AutoMerge, :holds})
    :persistent_term.erase({AutoMerge, :tried})

    {main, _origin} = GitRepo.with_origin()
    # The merge commits Merge makes need a committer, as the real repo has.
    GitRepo.git!(main, ["config", "user.name", "Merge"])
    GitRepo.git!(main, ["config", "user.email", "merge@example.com"])
    branch = "am-#{System.unique_integer([:positive])}"
    # The author's worktree, beside main's, as a stream has.
    feature = main <> "-#{branch}"
    GitRepo.git!(main, ["worktree", "add", "-q", "-b", branch, feature])

    tip =
      GitRepo.commit!(feature, %{"lib/feature.ex" => "defmodule Feature do\nend\n"}, "Feature")

    Application.put_env(:merge, :repo, main)
    Drift.put_current(nil)
    Drift.refresh(main)
    Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())

    on_exit(fn ->
      Application.put_env(:merge, :auto_merge, false)
      Application.put_env(:merge, :repo, was_repo)
      sync()
      MergeRequest.close(branch)
      Drift.put_current(nil)
      File.rm_rf!(feature)
    end)

    %{main: main, feature: feature, branch: branch, tip: tip, base: head(main)}
  end

  # The watcher has done what it was asked (an approval asks it to look).
  defp sync, do: if(pid = Process.whereis(Merge.Watcher), do: _ = :sys.get_state(pid))

  defp head(dir, ref \\ "HEAD"), do: dir |> GitRepo.git!(["rev-parse", ref]) |> String.trim()

  defp open!(c, attrs \\ %{}) do
    {:ok, mr, :opened} =
      MergeRequest.open(
        Map.merge(%{branch: c.branch, repo: c.feature, opened_by: "agent"}, attrs)
      )

    mr
  end

  defp approve!(c) do
    {:ok, _} = MergeRequest.decide(c.branch, :approved)
    sync()
  end

  # Approved while it was off, so the test says when it looks.
  defp approve_quietly!(c) do
    Application.put_env(:merge, :auto_merge, false)
    approve!(c)
    Application.put_env(:merge, :auto_merge, true)
  end

  # Only this test's merge requests: others' may still be registered.
  defp mine(results, branches), do: Enum.filter(results, fn {b, _} -> b in branches end)

  defp status(branch) do
    {:ok, mr} = MergeRequest.get(branch)
    mr.status
  end

  defp held_events(branch) do
    collect([]) |> Enum.filter(&(&1 =~ " auto-merge-held #{branch} "))
  end

  defp collect(acc) do
    receive do
      {:event, line} -> collect([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "turned off, an approval merges nothing", c do
    Application.put_env(:merge, :auto_merge, false)
    open!(c)
    approve!(c)

    assert head(c.main) == c.base
    assert status(c.branch) == :approved
    assert AutoMerge.run() == :off
  end

  test "a clean approved branch merges once, as a coordinator would", c do
    open!(c)
    approve!(c)

    sha = head(c.main)
    assert sha != c.base
    assert GitRepo.git!(c.main, ["log", "-1", "--format=%s"]) == "Merge #{c.branch}\n"
    assert GitRepo.git!(c.main, ["log", "-1", "--format=%P"]) == "#{c.base} #{c.tip}\n"
    assert {:ok, %{status: :merged, merged: %{sha: ^sha}}} = MergeRequest.get(c.branch)

    # merged, then auto-merged, then main's new tip.
    lines = collect([])
    merged = Enum.find_index(lines, &(&1 =~ " merged #{c.branch} "))
    auto = Enum.find_index(lines, &(&1 =~ " auto-merged #{c.branch} #{Events.short(sha)}"))
    tip = Enum.find_index(lines, &(&1 =~ " main-tip main "))
    assert merged < auto and auto < tip

    # Done: never again.
    assert mine(AutoMerge.run(), [c.branch]) == []
    assert head(c.main) == sha
    refute Enum.any?(collect([]), &(&1 =~ " auto-merged "))
  end

  test "uncommitted changes in main's worktree hold it, and say so once", c do
    open!(c)
    File.write!(Path.join(c.main, "lib/app.ex"), "defmodule App do\n  # mid-edit\nend\n")
    approve!(c)

    assert AutoMerge.hold(c.branch) == "main's worktree has uncommitted changes"
    assert [{_, {:hold, _}}] = AutoMerge.run(c.branch)
    assert head(c.main) == c.base
    assert length(held_events(c.branch)) == 1

    GitRepo.git!(c.main, ["checkout", "--", "lib/app.ex"])
    assert [{_, {:merged, _}}] = AutoMerge.run(c.branch)
    assert AutoMerge.hold(c.branch) == nil
  end

  test "a merge in progress in main's worktree holds it", c do
    GitRepo.git!(c.main, ["checkout", "-q", "-b", "side"])
    GitRepo.commit!(c.main, %{"SIDE.md" => "side\n"}, "Side")
    GitRepo.git!(c.main, ["checkout", "-q", "main"])
    GitRepo.git!(c.main, ["merge", "--no-commit", "--no-ff", "side"])
    open!(c)
    approve!(c)

    assert AutoMerge.hold(c.branch) == "a merge is in progress in main's worktree"
    assert head(c.main) == c.base
    # Someone else's merge is left alone.
    assert File.exists?(Path.join(c.main, ".git/MERGE_HEAD"))
  end

  test "a stacked request holds", c do
    GitRepo.git!(c.main, ["branch", "parent"])
    open!(c, %{base: "parent"})
    approve!(c)

    assert AutoMerge.hold(c.branch) == "stacked on parent, not main: merge it by hand"
    assert head(c.main) == c.base
  end

  test "an approval with an unanswered comment holds until it is answered", c do
    open!(c)
    {:ok, comment} = MergeRequest.comment(c.branch, %{body: "Rename this first"})
    approve!(c)

    assert AutoMerge.hold(c.branch) == "1 comment not answered (##{comment.id})"
    assert head(c.main) == c.base

    {:ok, _} = MergeRequest.reply(c.branch, comment.id, "Done in the next one", "agent")
    assert [{_, {:merged, _}}] = AutoMerge.run(c.branch)
  end

  test "a tip that moved after the approval holds", c do
    open!(c)
    approve_quietly!(c)
    moved = GitRepo.commit!(c.feature, %{"lib/more.ex" => "defmodule More do\nend\n"}, "Sneak")

    assert [{_, {:hold, reason}}] = AutoMerge.run(c.branch)

    assert reason ==
             "the branch moved after the approval (#{Events.short(c.tip)} → #{Events.short(moved)})"

    assert head(c.main) == c.base
  end

  test "a tip that moved only by a merge of main still merges", c do
    open!(c)
    approve_quietly!(c)

    GitRepo.commit!(c.main, %{"MAIN.md" => "main moved\n"}, "Main moves")
    GitRepo.git!(c.feature, ["merge", "-q", "--no-edit", "main"])

    assert [{_, {:merged, sha}}] = AutoMerge.run(c.branch)
    assert head(c.main) == sha
  end

  test "a merge of main with something of its own in it holds", c do
    open!(c)
    approve_quietly!(c)

    GitRepo.commit!(c.main, %{"MAIN.md" => "main moved\n"}, "Main moves")
    GitRepo.git!(c.feature, ["merge", "-q", "--no-commit", "main"])

    File.write!(
      Path.join(c.feature, "lib/feature.ex"),
      "defmodule Feature do\n  def sneak, do: 1\nend\n"
    )

    GitRepo.git!(c.feature, ["add", "-A"])
    GitRepo.git!(c.feature, ["commit", "-q", "--no-edit"])
    before = head(c.main)

    assert [{_, {:hold, "the branch moved after the approval" <> _}}] = AutoMerge.run(c.branch)
    assert head(c.main) == before
  end

  test "a red main holds it, and a green one lets it through", c do
    open!(c)
    approve_quietly!(c)

    red = [checks_on: true, checks: %{sha: c.base, ok: false}, image: :not_needed]

    assert [{_, {:hold, "main's checks failed on " <> _}}] = AutoMerge.run(c.branch, red)
    assert head(c.main) == c.base

    image = [checks_on: true, checks: %{sha: c.base, ok: true}, image: %{sha: c.base, ok: false}]
    assert [{_, {:hold, "main's image build failed on " <> _}}] = AutoMerge.run(c.branch, image)

    green = [checks_on: true, checks: %{sha: c.base, ok: true}, image: :not_needed]
    assert [{_, {:merged, _}}] = AutoMerge.run(c.branch, green)
  end

  test "a conflict holds it, and once resolved it merges", c do
    GitRepo.commit!(
      c.feature,
      %{"lib/app.ex" => "defmodule App do\n  def a, do: :branch\nend\n"},
      "Branch"
    )

    GitRepo.commit!(
      c.main,
      %{"lib/app.ex" => "defmodule App do\n  def a, do: :main\nend\n"},
      "Main"
    )

    main_tip = head(c.main)
    open!(c)
    approve!(c)

    assert AutoMerge.hold(c.branch) == "conflicts with main: lib/app.ex"
    assert head(c.main) == main_tip

    # The author merges main in and resolves it: a merge of main, so still approved.
    {_, 1} = System.cmd("git", ["-C", c.feature, "merge", "main"], stderr_to_stdout: true)
    File.write!(Path.join(c.feature, "lib/app.ex"), "defmodule App do\n  def a, do: :both\nend\n")
    GitRepo.git!(c.feature, ["add", "-A"])
    GitRepo.git!(c.feature, ["commit", "-q", "--no-edit"])

    assert [{_, {:merged, sha}}] = AutoMerge.run(c.branch)
    assert head(c.main) == sha
    assert File.read!(Path.join(c.main, "lib/app.ex")) =~ ":both"
  end

  test "a merge that fails halfway is aborted, leaves main as it was, and isn't tried again",
       c do
    hook = Path.join(c.main, ".git/hooks/pre-merge-commit")
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\necho 'refused by the hook' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)
    open!(c)
    approve!(c)

    assert "the merge failed, main is as it was" <> _ = AutoMerge.hold(c.branch)
    assert head(c.main) == c.base
    assert GitRepo.git!(c.main, ["status", "--porcelain"]) == ""
    refute File.exists?(Path.join(c.main, ".git/MERGE_HEAD"))
    refute File.exists?(Path.join(c.main, "lib/feature.ex"))
    assert status(c.branch) == :approved

    # Not again for the same branch and main, even once the hook would let it.
    File.rm!(hook)
    assert [{_, {:hold, "the merge failed" <> _}}] = AutoMerge.run(c.branch)
    assert head(c.main) == c.base
    assert length(held_events(c.branch)) == 1

    # main moves on: it tries again.
    GitRepo.commit!(c.main, %{"MAIN.md" => "main moved\n"}, "Main moves")
    assert [{_, {:merged, _}}] = AutoMerge.run(c.branch)
  end

  test "approved ones merge oldest approval first", c do
    second = c.branch <> "-b"
    GitRepo.git!(c.main, ["branch", second])
    other = c.feature <> "-b"
    GitRepo.git!(c.main, ["worktree", "add", "-q", other, second])
    GitRepo.commit!(other, %{"lib/b.ex" => "defmodule B do\nend\n"}, "B")
    on_exit(fn -> MergeRequest.close(second) end)

    Application.put_env(:merge, :auto_merge, false)
    {:ok, _, :opened} = MergeRequest.open(%{branch: second, repo: other})
    open!(c)
    {:ok, _} = MergeRequest.decide(second, :approved)
    {:ok, _} = MergeRequest.decide(c.branch, :approved)
    sync()
    Application.put_env(:merge, :auto_merge, true)

    assert [{^second, {:merged, _}}, {first, {:merged, _}}] =
             mine(AutoMerge.run(), [c.branch, second])

    assert first == c.branch

    assert GitRepo.git!(c.main, ["log", "-2", "--format=%s"]) ==
             "Merge #{c.branch}\nMerge #{second}\n"
  end
end
