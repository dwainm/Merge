defmodule Gitastic.MergeRequestTest do
  # The registry is global, so each test uses its own branch name.
  use ExUnit.Case, async: true

  alias Gitastic.{GitRepo, MergeRequest}

  setup do
    branch = "mr-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)

    {:ok, mr, :opened} =
      MergeRequest.open(%{branch: branch, repo: repo, title: "Empty it", opened_by: "agent-a"})

    %{branch: branch, repo: repo, mr: mr}
  end

  test "opening holds the branch, the commits and the diff", %{mr: mr, repo: repo} do
    assert %{title: "Empty it", base: "main", opened_by: "agent-a", status: :open} = mr
    assert mr.repo == repo
    assert [%{subject: "Empty the app"}] = mr.commits
    assert [%{path: "lib/app.ex"}] = mr.files
    assert mr.agents == ["agent-a"]
  end

  test "opening again registers the second agent on the same merge request", c do
    assert {:ok, mr, :existing} =
             MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent-b"})

    assert mr.agents == ["agent-a", "agent-b"]
    assert Enum.count(MergeRequest.list(), &(&1.branch == c.branch)) == 1
  end

  test "a stacked branch is reviewed against its parent", %{branch: parent, repo: repo} do
    child = parent <> "-child"
    GitRepo.git!(repo, ["checkout", "-q", "-b", child])
    GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")
    on_exit(fn -> MergeRequest.close(child) end)

    assert {:ok, mr, :opened} = MergeRequest.open(%{branch: child, repo: repo, base: parent})

    assert %{base: ^parent, commits: [%{subject: "Add a readme"}], files: [%{path: "README.md"}]} =
             mr
  end

  test "a branch that isn't there doesn't open", %{repo: repo} do
    assert {:error, message} = MergeRequest.open(%{branch: "no-such-branch", repo: repo})
    assert message =~ "no-such-branch"
  end

  test "a comment wakes every waiting agent, and the next wait returns only what is new", c do
    a = Task.async(fn -> MergeRequest.wait(c.branch, "agent-a", 5_000) end)
    b = Task.async(fn -> MergeRequest.wait(c.branch, "agent-b", 5_000) end)
    wait_for_waiters(c.branch, 2)

    {:ok, _} =
      MergeRequest.comment(c.branch, %{body: "Why empty?", path: "lib/app.ex", line: 2})

    for task <- [a, b] do
      assert {:ok, %{kind: :comment, comments: [%{body: "Why empty?", line: 2}]}} =
               Task.await(task)
    end

    # Said while agent-a re-arms: not missed, and the first comment isn't repeated.
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "And the test?"})
    {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "Keep hello.")

    assert {:ok, %{kind: :decision, decision: %{verdict: :needs_work}, comments: [only]}} =
             MergeRequest.wait(c.branch, "agent-a", 5_000)

    assert only.body == "And the test?"

    # Nothing new since: the next wait blocks.
    assert {:ok, :timeout} = MergeRequest.wait(c.branch, "agent-a", 50)
  end

  test "an agent that hasn't heard anything yet gets it all at once", c do
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Fine."})
    {:ok, _} = MergeRequest.decide(c.branch, :approved)

    assert {:ok, %{kind: :decision, status: :approved, comments: [%{body: "Fine."}]}} =
             MergeRequest.wait(c.branch, "late-agent", 5_000)

    assert {:ok, %{agents: ["agent-a", "late-agent"]}} = MergeRequest.get(c.branch)
  end

  test "rejecting needs a comment", c do
    assert {:error, _} = MergeRequest.decide(c.branch, :needs_work, "")
    assert {:ok, %{status: :open, decisions: []}} = MergeRequest.get(c.branch)
  end

  test "addressed answers the decision with a commit, recomputes the diff and waits again", c do
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Keep hello."})
    {:ok, _} = MergeRequest.decide(c.branch, :needs_work)
    assert {:ok, %{kind: :decision}} = MergeRequest.wait(c.branch, "agent-a", 5_000)
    Phoenix.PubSub.subscribe(Gitastic.PubSub, MergeRequest.topic(c.branch))

    sha =
      GitRepo.commit!(
        c.repo,
        %{"lib/app.ex" => "defmodule App do\n  def hello, do: :world\nend\n"},
        "Keep hello"
      )

    assert {:ok, %{sha: ^sha, note: "Put it back", round: 0}} =
             MergeRequest.addressed(c.branch, sha, "Put it back")

    assert_receive {:merge_request, %{status: :open, head: ^sha} = mr}
    assert [%{sha: ^sha} | _] = mr.commits
    # Back to the same content as main, so nothing left to diff.
    assert mr.files == []

    # Heard already: wait blocks until there is news.
    assert {:ok, :timeout} = MergeRequest.wait(c.branch, "agent-a", 50)

    task = Task.async(fn -> MergeRequest.wait(c.branch, "agent-a", 5_000) end)
    wait_for_waiters(c.branch, 1)
    {:ok, _} = MergeRequest.decide(c.branch, :approved, "Good.")

    assert {:ok, %{kind: :decision, status: :approved, comments: []}} = Task.await(task)
  end

  test "addressed refuses a commit that is not on the branch", c do
    GitRepo.git!(c.repo, ["checkout", "-q", "main"])
    other = GitRepo.commit!(c.repo, %{"x" => "x"}, "On main")
    assert {:error, message} = MergeRequest.addressed(c.branch, other)
    assert message =~ "not on"
  end

  test "closing tells waiting agents and keeps it, read-only", c do
    task = Task.async(fn -> MergeRequest.wait(c.branch, "agent-a", 5_000) end)
    wait_for_waiters(c.branch, 1)

    assert {:ok, :closed} = MergeRequest.close(c.branch)
    assert {:ok, %{status: :closed}} = Task.await(task)
    assert {:ok, %{status: :closed, files: [_]}} = MergeRequest.get(c.branch)
    assert {:error, _} = MergeRequest.comment(c.branch, %{body: "Late"})
    assert {:ok, %{status: :closed}} = MergeRequest.wait(c.branch, "late", 5_000)
  end

  test "closing an approved one marks it merged, and opening the branch again starts afresh", c do
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Fine."})
    {:ok, _} = MergeRequest.decide(c.branch, :approved)
    assert {:ok, :merged} = MergeRequest.close(c.branch)

    assert {:ok, %{status: :open, comments: [], decisions: []}, :opened} =
             MergeRequest.open(%{branch: c.branch, repo: c.repo})
  end

  defp wait_for_waiters(branch, n) do
    case MergeRequest.get(branch) do
      {:ok, %{waiting: waiting}} when length(waiting) == n -> :ok
      _ -> wait_for_waiters(branch, n)
    end
  end
end
