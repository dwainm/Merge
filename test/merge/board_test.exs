defmodule Merge.BoardTest do
  use ExUnit.Case, async: true

  alias Merge.{Board, GitRepo, MergeRequest}

  setup do
    branch = "board-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)
    {:ok, mr, :opened} = MergeRequest.open(%{branch: branch, repo: repo, opened_by: "agent-a"})
    %{branch: branch, repo: repo, mr: mr}
  end

  test "a merge request is read while its process is busy", c do
    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    # As busy as it gets: it answers nothing until resumed.
    :ok = :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

    assert {:ok, mr} = MergeRequest.get(c.branch)
    assert mr == c.mr

    assert [%{files: [], file_count: 1}] =
             Enum.filter(MergeRequest.list(), &(&1.branch == c.branch))

    :ok = :sys.resume(pid)
  end

  test "every change is on the board before anyone is told", c do
    Phoenix.PubSub.subscribe(Merge.PubSub, MergeRequest.topic(c.branch))
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Why empty?"})
    assert_receive {:merge_request, told}
    assert Board.get(c.branch) == told
    assert [%{body: "Why empty?"}] = told.comments
    assert %{comments: [_]} = Board.summaries()[c.branch]
  end

  test "one not on the board yet is asked once, and is on it after", c do
    Board.delete(c.branch)
    assert {:ok, mr} = MergeRequest.get(c.branch)
    assert mr == c.mr
    assert Board.get(c.branch) == mr

    Board.delete(c.branch)
    assert Enum.any?(MergeRequest.list(), &(&1.branch == c.branch))
    assert %{file_count: 1} = Board.summaries()[c.branch]
  end

  test "a done one making way for a new one on its branch leaves no old row", c do
    {:ok, :closed} = MergeRequest.close(c.branch)
    assert {:ok, %{status: :closed}} = MergeRequest.get(c.branch)

    {:ok, mr, :opened} =
      MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent-b"})

    assert mr.status == :open
    assert {:ok, %{status: :open, opened_by: "agent-b"}} = MergeRequest.get(c.branch)
  end
end
