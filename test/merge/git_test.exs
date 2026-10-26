defmodule Merge.GitTest do
  use ExUnit.Case, async: true

  alias Merge.{Git, GitRepo}

  setup do
    repo = GitRepo.new()

    one =
      GitRepo.commit!(
        repo,
        %{"lib/app.ex" => "defmodule App do\n  def hello, do: :there\nend\n"},
        "Say there"
      )

    two = GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")
    %{repo: repo, one: one, two: two}
  end

  test "the commits on the branch, newest first, without main's", %{repo: repo} = c do
    assert {:ok, [%{sha: two, subject: "Add a readme"}, %{sha: one, subject: "Say there"}]} =
             Git.commits(repo, "main", "feature")

    assert {two, one} == {c.two, c.one}
  end

  test "the branch diff against main, from the merge base", %{repo: repo} do
    # A commit on main after the branch point stays out of the branch's diff.
    GitRepo.git!(repo, ["checkout", "-q", "main"])
    GitRepo.commit!(repo, %{"lib/other.ex" => "x\n"}, "On main")

    assert {:ok, files} = Git.branch_diff(repo, "main", "feature")
    assert [%{path: "README.md", status: :added}, app] = files
    assert %{path: "lib/app.ex", status: :modified, additions: 1, deletions: 1} = app

    [hunk] = app.hunks
    assert [_, del, add, _] = hunk.lines
    assert %{type: :del, old: 2, new: nil, text: "  def hello, do: :world"} = del
    assert %{type: :add, old: nil, new: 2, text: "  def hello, do: :there"} = add
    # Coloured by the Elixir lexer.
    assert add.html =~ ~s(class="kd")
  end

  test "one commit's diff alone", %{repo: repo, two: two} do
    assert {:ok, [%{path: "README.md", additions: 1}]} = Git.commit_diff(repo, two)
  end

  test "renames and deletions", %{repo: repo} do
    GitRepo.git!(repo, ["mv", "README.md", "GUIDE.md"])
    GitRepo.git!(repo, ["rm", "-q", "lib/app.ex"])
    GitRepo.git!(repo, ["commit", "-q", "-m", "Move"])

    assert {:ok, files} = Git.commit_diff(repo, "HEAD")

    assert [%{path: "GUIDE.md", old_path: "README.md", status: :renamed}, deleted] =
             Enum.sort_by(files, & &1.path)

    assert %{path: "lib/app.ex", status: :deleted, deletions: 3} = deleted
  end

  test "the tree at a ref, and the contents of many paths in one call", %{repo: repo} do
    {:ok, tree} = Git.ls_tree(repo, "main")
    assert "lib/app.ex" in tree

    assert %{"lib/app.ex" => "defmodule App do" <> _} =
             contents = Git.cat(repo, "main", ["lib/app.ex", "lib/missing.ex", "lib/app.ex"])

    refute Map.has_key?(contents, "lib/missing.ex")
    assert Git.cat(repo, "main", []) == %{}
  end

  test "a ref that isn't there", %{repo: repo} do
    assert {:error, message} = Git.rev_parse(repo, "nope")
    assert message =~ "nope"
  end

  describe "merge_into" do
    # GitHub and main both moved on from the same commit.
    defp diverged(their_files) do
      {repo, origin} = GitRepo.with_origin()
      other = Path.join(Path.dirname(origin), "other")
      {_, 0} = System.cmd("git", ["clone", "-q", origin, other], stderr_to_stdout: true)
      theirs = GitRepo.commit!(other, their_files, "Elsewhere")
      GitRepo.git!(other, ["push", "-q", "origin", "main"])
      Git.fetch(repo)
      identify(repo)
      {repo, origin, theirs}
    end

    # A merge commit is made by git itself, so the repo says who makes it.
    defp identify(repo) do
      GitRepo.git!(repo, ["config", "user.name", "Test"])
      GitRepo.git!(repo, ["config", "user.email", "test@example.com"])
    end

    test "merges GitHub's main into the checked-out main with a merge commit" do
      {repo, _origin, theirs} = diverged(%{"OTHER.md" => "x\n"})
      mine = GitRepo.commit!(repo, %{"MINE.md" => "y\n"}, "Mine")

      assert {:ok, sha} =
               Git.merge_into(repo, "main", "origin/main", "Merge GitHub's main into main")

      assert {:ok, ^sha} = Git.rev_parse(repo, "main")
      assert Git.ancestor?(repo, mine, sha) and Git.ancestor?(repo, theirs, sha)

      assert GitRepo.git!(repo, ["log", "-1", "--format=%s %P"]) =~
               "Merge GitHub's main into main #{mine} #{theirs}"

      assert File.read!(Path.join(repo, "OTHER.md")) == "x\n"
    end

    test "works in a bare repo, where nothing is checked out" do
      {repo, origin, theirs} = diverged(%{"OTHER.md" => "x\n"})
      mine = GitRepo.commit!(repo, %{"MINE.md" => "y\n"}, "Mine")
      bare = Path.join(Path.dirname(origin), "bare.git")
      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", repo, bare], stderr_to_stdout: true)
      GitRepo.git!(bare, ["remote", "set-url", "origin", origin])
      identify(bare)
      GitRepo.git!(bare, ["fetch", "-q", "origin", "+refs/heads/*:refs/remotes/origin/*"])

      assert {:ok, sha} =
               Git.merge_into(bare, "main", "origin/main", "Merge GitHub's main into main")

      assert {:ok, ^sha} = Git.rev_parse(bare, "main")
      assert Git.ancestor?(bare, mine, sha) and Git.ancestor?(bare, theirs, sha)

      assert {:ok, %{"OTHER.md" => "x\n", "MINE.md" => "y\n"}} =
               {:ok, Git.cat(bare, "main", ["OTHER.md", "MINE.md"])}
    end

    test "a conflict changes nothing and names the files" do
      {repo, _origin, _theirs} = diverged(%{"lib/app.ex" => "theirs\n"})
      mine = GitRepo.commit!(repo, %{"lib/app.ex" => "mine\n"}, "Mine")

      assert {:conflicts, ["lib/app.ex"]} = Git.merge_into(repo, "main", "origin/main", "Merge")
      assert {:ok, ^mine} = Git.rev_parse(repo, "main")
    end
  end
end
