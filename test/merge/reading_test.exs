defmodule Merge.ReadingTest do
  # It puts a slow `git` first on the PATH, which is one for the whole VM; the
  # stand-in is slow only for commands that name this test's branch.
  use ExUnit.Case, async: false

  alias Merge.{GitRepo, MergeRequest}

  @slow_ms 1_500

  setup do
    branch = "slow-git-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, opened_by: "agent-a"})

    dir = Path.join(System.tmp_dir!(), "merge-slow-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git = System.find_executable("git")

    File.write!(Path.join(dir, "git"), """
    #!/bin/sh
    case "$*" in *#{branch}*) sleep #{@slow_ms / 1000} ;; esac
    exec #{git} "$@"
    """)

    File.chmod!(Path.join(dir, "git"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
      MergeRequest.close(branch)
    end)

    %{branch: branch, repo: repo}
  end

  defp quick(fun) do
    {us, result} = :timer.tc(fun)
    assert us < @slow_ms * 1000 / 3, "took #{div(us, 1000)} ms: it waited on git"
    result
  end

  test "while git reads the branch, the merge request answers everything else", c do
    sha = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    look = Task.async(fn -> MergeRequest.check_branch(c.branch) end)

    assert {:ok, _} = quick(fn -> MergeRequest.comment(c.branch, %{body: "Why empty?"}) end)
    assert {:ok, _} = quick(fn -> MergeRequest.decide(c.branch, :needs_work, "Keep hello.") end)
    assert {:ok, %{status: :in_progress}} = quick(fn -> MergeRequest.get(c.branch) end)
    assert {:ok, %{kind: :decision}} = quick(fn -> MergeRequest.wait(c.branch, "agent-a", 10) end)

    # The look was still on its way all that time, and lands whole.
    assert Task.yield(look, 0) == nil
    assert :ok = Task.await(look, 10_000)
    assert {:ok, %{head: ^sha, comments: [_], decisions: [_]} = mr} = MergeRequest.get(c.branch)
    assert [%{subject: "Add a readme"}, %{subject: "Empty the app"}] = mr.commits
  end

  test "addressed says the page is reading, then that it is read", c do
    {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "Keep hello.")
    sha = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    Phoenix.PubSub.subscribe(Merge.PubSub, MergeRequest.topic(c.branch))

    assert {:ok, %{sha: ^sha}} = MergeRequest.addressed(c.branch, sha, "Added a readme")
    # First as it was, marked as being read; then with the new commit.
    assert_received {:merge_request, %{reading: true, status: :open, commits: [_]}}
    assert_received {:merge_request, %{reading: false, head: ^sha, commits: [_, _]}}
    assert {:ok, %{reading: false, files: [_, _]}} = MergeRequest.get(c.branch)
  end

  test "a reading that dies lets its caller go, and the next look reads again", c do
    sha = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    look = Task.async(fn -> MergeRequest.check_branch(c.branch) end)

    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    # As a code load does to a process in the middle of old code.
    reader = wait_for_reader(pid)
    Process.exit(reader, :kill)

    assert :ok = Task.await(look, 10_000)
    assert :ok = MergeRequest.check_branch(c.branch)
    assert {:ok, %{head: ^sha}} = MergeRequest.get(c.branch)
  end

  defp wait_for_reader(pid) do
    case :sys.get_state(pid).job do
      %{pid: reader} -> reader
      nil -> wait_for_reader(pid)
    end
  end
end
