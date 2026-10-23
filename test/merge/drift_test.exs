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

  test "a push up to one of the commits ahead leaves the rest ahead", %{repo: repo} do
    one = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    two = GitRepo.commit!(repo, %{"TWO.md" => "2\n"}, "Two")
    three = GitRepo.commit!(repo, %{"THREE.md" => "3\n"}, "Three")

    assert %{ok: true, commits: [%{sha: ^two}, %{sha: ^one}], origin: ^two, identical: false} =
             result = Drift.push(repo, two)

    assert [%{sha: ^three}] = result.left
    assert %{ahead: [%{sha: ^three}], behind: [], origin: ^two} = Drift.read(repo)

    assert %{ok: false, output: "bad0000 is not ahead of GitHub.", commits: []} =
             Drift.push(repo, "bad0000bad0000")

    assert %{ok: true, left: [], identical: true} = Drift.push(repo, three)
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
