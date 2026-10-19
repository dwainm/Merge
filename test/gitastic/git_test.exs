defmodule Gitastic.GitTest do
  use ExUnit.Case, async: true

  alias Gitastic.{Git, GitRepo}

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

  test "a ref that isn't there", %{repo: repo} do
    assert {:error, message} = Git.rev_parse(repo, "nope")
    assert message =~ "nope"
  end
end
