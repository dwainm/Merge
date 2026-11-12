defmodule Merge.OwnBaseTest do
  @moduledoc """
  A branch reviewed against origin/main that merged in local main, ahead of
  GitHub with another stream's work: its counts and files are its own.
  """
  use ExUnit.Case, async: true

  import Merge.GitRepo, only: [commit!: 3, git!: 2]

  alias Merge.{Git, GitRepo, MergeRequest}

  test "merging in local main ahead of origin/main brings nothing into the branch's own" do
    {clone, _origin} = GitRepo.with_origin()
    branch = "own-base-#{System.unique_integer([:positive])}"
    on_exit(fn -> MergeRequest.close(branch) end)

    git!(clone, ["checkout", "-q", "-b", branch])
    commit!(clone, %{"lib/feature.ex" => "feature\n"}, "Feature")
    git!(clone, ["checkout", "-q", "main"])
    commit!(clone, %{"lib/other.ex" => "other\n"}, "Another stream, not pushed")
    git!(clone, ["checkout", "-q", branch])
    git!(clone, ["merge", "-q", "--no-edit", "main"])

    assert Git.own_base(clone, "origin/main", branch) == "main"

    {:ok, mr, :opened} = MergeRequest.open(%{branch: branch, repo: clone})
    assert mr.base == "origin/main"
    assert Enum.map(mr.files, & &1.path) == ["lib/feature.ex"]
    assert [%{merge_of: "main"}, %{subject: "Feature"}] = mr.commits
    assert [%{subject: "Feature"}] = MergeRequest.own_commits(mr)
  end

  test "a branch already on local main is judged against origin/main" do
    {clone, _origin} = GitRepo.with_origin()
    commit!(clone, %{"lib/other.ex" => "other\n"}, "On main")
    assert Git.own_base(clone, "origin/main", "main") == "origin/main"
    assert Git.own_base(clone, "main", "main") == "main"
  end
end
