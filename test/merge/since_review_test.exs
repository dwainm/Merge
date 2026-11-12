defmodule Merge.SinceReviewTest do
  @moduledoc """
  "Since your review" is the author's own change: a branch reviewed at one
  head, main moving on, and the branch merging main in, cleanly or with a
  conflict resolved by hand.
  """
  use ExUnit.Case, async: true

  alias Merge.{Git, GitRepo}

  import GitRepo, only: [commit!: 3, git!: 2]

  # main: lib/app.ex; the branch adds lib/feature.ex and edits lib/shared.ex,
  # and is reviewed there.
  setup do
    repo = GitRepo.new("feature")
    git!(repo, ["checkout", "-q", "main"])
    commit!(repo, %{"lib/shared.ex" => "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"}, "Shared")
    git!(repo, ["checkout", "-q", "feature"])
    git!(repo, ["merge", "-q", "--ff-only", "main"])

    reviewed =
      commit!(
        repo,
        %{
          "lib/feature.ex" => "feature\n",
          "lib/shared.ex" => "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\n"
        },
        "The feature"
      )

    %{repo: repo, reviewed: reviewed}
  end

  defp on_main(repo, files, message) do
    git!(repo, ["checkout", "-q", "main"])
    commit!(repo, files, message)
    git!(repo, ["checkout", "-q", "feature"])
  end

  defp merge_main(repo) do
    git!(repo, ["merge", "-q", "--no-edit", "main"])
    head(repo)
  end

  # A merge of main that conflicts, resolved by hand to `files`.
  defp merge_main_resolving(repo, files) do
    identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]
    args = ["-C", repo] ++ identity ++ ["merge", "-q", "--no-edit", "main"]
    {_, 1} = System.cmd("git", args, stderr_to_stdout: true)
    commit!(repo, files, "Merge branch 'main' into feature")
  end

  defp head(repo), do: repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
  defp paths({:ok, files}), do: files |> Enum.map(& &1.path) |> Enum.sort()

  test "main moved with other files and was merged in cleanly: nothing of the author's", c do
    on_main(c.repo, %{"lib/other.ex" => "other\n", "lib/more.ex" => "more\n"}, "Another stream")
    head = merge_main(c.repo)

    assert paths(Git.since_diff(c.repo, "main", c.reviewed, head)) == []
    # The plain diff, what this used to show, has the other stream's files.
    assert paths(Git.range_diff(c.repo, c.reviewed, head)) == ["lib/more.ex", "lib/other.ex"]
    assert paths(Git.remerge_diff(c.repo, head)) == []
  end

  test "main changed a file the branch changed too, merging cleanly: it drops out", c do
    on_main(c.repo, %{"lib/shared.ex" => "one\ntwo\nthree\nfour\nfive\nsix\nSEVEN\n"}, "Seven")
    head = merge_main(c.repo)

    assert paths(Git.since_diff(c.repo, "main", c.reviewed, head)) == []
  end

  test "the author's commits after the review show, and only theirs", c do
    commit!(c.repo, %{"lib/feature.ex" => "feature, better\n"}, "Better")
    on_main(c.repo, %{"lib/other.ex" => "other\n"}, "Another stream")
    merge_main(c.repo)
    head = commit!(c.repo, %{"test/feature_test.exs" => "test\n"}, "A test")

    assert paths(Git.since_diff(c.repo, "main", c.reviewed, head)) ==
             ["lib/feature.ex", "test/feature_test.exs"]
  end

  test "a conflict resolved by hand is the author's change and shows", c do
    on_main(
      c.repo,
      %{
        "lib/shared.ex" => "uno\ntwo\nthree\nfour\nfive\nsix\nseven\n",
        "lib/other.ex" => "other\n"
      },
      "Uno"
    )

    head =
      merge_main_resolving(c.repo, %{
        "lib/shared.ex" => "ONE uno\ntwo\nthree\nfour\nfive\nsix\nseven\n"
      })

    assert {:ok, [file]} = Git.since_diff(c.repo, "main", c.reviewed, head)
    assert file.path == "lib/shared.ex"

    # The merge commit's own diff is that resolution, not main's lib/other.ex.
    assert paths(Git.remerge_diff(c.repo, head)) == ["lib/shared.ex"]
  end

  test "with main unmoved it is the plain diff from the reviewed head", c do
    head = commit!(c.repo, %{"lib/feature.ex" => "feature, better\n"}, "Better")

    assert Git.since_diff(c.repo, "main", c.reviewed, head) ==
             Git.range_diff(c.repo, c.reviewed, head)
  end

  test "an ordinary commit is not a merge", c do
    assert {:error, _} = Git.remerge_diff(c.repo, c.reviewed)
  end
end
