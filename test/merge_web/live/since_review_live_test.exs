defmodule MergeWeb.SinceReviewLiveTest do
  @moduledoc """
  The page after main is merged into a reviewed branch: "Since your review"
  holds only the author's changes, the merge of main is folded in the commit
  list and shows only what the author did in it, and one quiet line says main
  moved.
  """
  use MergeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Merge.GitRepo, only: [commit!: 3, git!: 2]

  alias Merge.{GitRepo, MergeRequest}

  setup do
    branch = "since-live-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    git!(repo, ["checkout", "-q", "main"])
    commit!(repo, %{"lib/shared.ex" => "one\ntwo\nthree\n"}, "Shared")
    git!(repo, ["checkout", "-q", branch])
    git!(repo, ["merge", "-q", "--ff-only", "main"])

    commit!(
      repo,
      %{"lib/feature.ex" => "feature\n", "lib/shared.ex" => "ONE\ntwo\nthree\n"},
      "Feature"
    )

    on_exit(fn -> MergeRequest.close(branch) end)
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Feature"})
    {:ok, _} = MergeRequest.decide(branch, :needs_work, "Add a test")
    %{branch: branch, repo: repo}
  end

  defp on_main(c, files) do
    git!(c.repo, ["checkout", "-q", "main"])
    commit!(c.repo, files, "Another stream")
    git!(c.repo, ["checkout", "-q", c.branch])
  end

  defp merge_main(c) do
    git!(c.repo, ["merge", "-q", "--no-edit", "main"])
    c.repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp short(sha), do: String.slice(sha, 0, 7)

  # Other tests emit events too: the first line ending in `tail`, if any.
  defp event_ending(tail) do
    receive do
      {:event, line} -> String.ends_with?(line, tail) or event_ending(tail)
    after
      1000 -> false
    end
  end

  test "main merged in cleanly: nothing to read, one quiet line, the merge folded",
       %{conn: conn} = c do
    on_main(c, %{"lib/other.ex" => "other\n", "lib/more.ex" => "more\n"})
    merge = merge_main(c)
    Phoenix.PubSub.subscribe(Merge.PubSub, Merge.Events.topic())
    :ok = MergeRequest.check_branch(c.branch)
    assert event_ending(" new-commits #{c.branch} main merged in → #{short(merge)}")

    {:ok, mr} = MergeRequest.get(c.branch)
    assert [%{merge_of: "main", from_base: 2, own_files: 0}, %{subject: "Feature"}] = mr.commits
    assert length(MergeRequest.own_commits(mr)) == 1
    # The branch's own files, not the other stream's.
    assert mr.files |> Enum.map(& &1.path) |> Enum.sort() == ["lib/feature.ex", "lib/shared.ex"]

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(view, "#base-moved", "has moved since your review")
    # Nothing of the author's is new.
    refute has_element?(view, "#since-review")
    assert has_element?(view, "#base-merge-#{short(merge)}", "Merged main in, 2 files from main")
    refute has_element?(view, "#base-merge-#{short(merge)} span", "resolved")

    {:ok, since, _html} = live(conn, MergeWeb.mr_path(c.branch) <> "?since=review")
    assert has_element?(since, "#no-changes", "Nothing of the author's since your review")
    refute has_element?(since, "#file-0")

    {:ok, one, _html} = live(conn, MergeWeb.mr_path(c.branch) <> "?commit=" <> merge)
    assert has_element?(one, "#no-changes", "Nothing of the author's: main merged cleanly")
  end

  test "the author's work after the review shows and is new; main's doesn't",
       %{conn: conn} = c do
    on_main(c, %{"lib/other.ex" => "other\n"})
    merge_main(c)
    test_commit = commit!(c.repo, %{"test/feature_test.exs" => "test\n"}, "A test")
    :ok = MergeRequest.check_branch(c.branch)

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(view, "#since-review", "1 new commit since your last review")
    assert has_element?(view, "#commit-#{short(test_commit)}", "new")
    assert has_element?(view, "#base-merges-count", "1 merge of main")

    {:ok, since, _html} = live(conn, MergeWeb.mr_path(c.branch) <> "?since=review")
    assert has_element?(since, "#file-0", "test/feature_test.exs")
    refute has_element?(since, "#file-1")
  end

  test "a conflict resolved by hand shows, in the merge and since the review",
       %{conn: conn} = c do
    on_main(c, %{"lib/shared.ex" => "uno\ntwo\nthree\n", "lib/other.ex" => "other\n"})
    identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]

    {_, 1} =
      System.cmd("git", ["-C", c.repo] ++ identity ++ ["merge", "main"], stderr_to_stdout: true)

    merge = commit!(c.repo, %{"lib/shared.ex" => "ONE uno\ntwo\nthree\n"}, "Merge main")
    :ok = MergeRequest.check_branch(c.branch)

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(view, "#base-merge-#{short(merge)}", "1 resolved")

    {:ok, one, _html} = live(conn, MergeWeb.mr_path(c.branch) <> "?commit=" <> merge)
    assert has_element?(one, "#file-0", "lib/shared.ex")
    refute has_element?(one, "#file-1")

    {:ok, since, _html} = live(conn, MergeWeb.mr_path(c.branch) <> "?since=review")
    assert has_element?(since, "#file-0", "lib/shared.ex")
    refute has_element?(since, "#file-1")
  end

  test "with main unmoved there is no line about it", %{conn: conn} = c do
    commit!(c.repo, %{"test/feature_test.exs" => "test\n"}, "A test")
    :ok = MergeRequest.check_branch(c.branch)

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    refute has_element?(view, "#base-moved")
    refute has_element?(view, "#base-merges-count")
  end
end
