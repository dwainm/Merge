defmodule Merge.DriftTest do
  use ExUnit.Case, async: true

  alias Merge.{Drift, Git, GitRepo}

  setup do
    {clone, origin} = GitRepo.with_origin()
    %{repo: clone, origin: origin}
  end

  test "reads main against origin/main, and a push brings them together, checked by a fetch",
       %{repo: repo} do
    assert %{ahead: [], behind: []} = Drift.read(repo)

    sha = GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")
    assert %{ahead: [%{sha: ^sha, subject: "Add a readme"}], behind: []} = Drift.read(repo)

    assert %{ok: true, commits: [%{sha: ^sha}], origin: ^sha, identical: true} = Drift.push(repo)
    assert %{ahead: [], behind: []} = Drift.read(repo)
  end

  test "a rejected push says so and changes nothing", %{repo: repo, origin: origin} do
    # GitHub moves on without us: our main and theirs diverge.
    other = Path.join(Path.dirname(origin), "other")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, other], stderr_to_stdout: true)
    GitRepo.commit!(other, %{"OTHER.md" => "x\n"}, "Elsewhere")
    GitRepo.git!(other, ["push", "-q", "origin", "main"])
    mine = GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")

    assert %{ok: false, output: output, commits: [%{sha: ^mine}]} = Drift.push(repo)
    assert output =~ "rejected"
    assert %{ahead: [%{sha: ^mine}], behind: [%{subject: "Elsewhere"}]} = Drift.read(repo)
  end

  test "pull moves main to GitHub's, fast-forward only", %{repo: repo, origin: origin} do
    other = Path.join(Path.dirname(origin), "other")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, other], stderr_to_stdout: true)
    theirs = GitRepo.commit!(other, %{"OTHER.md" => "x\n"}, "Elsewhere")
    GitRepo.git!(other, ["push", "-q", "origin", "main"])
    Git.fetch(repo)

    assert %{behind: [%{sha: ^theirs}]} = Drift.read(repo)
    assert {:ok, _} = Drift.pull(repo)
    assert %{ahead: [], behind: [], main: ^theirs} = Drift.read(repo)
  end
end
