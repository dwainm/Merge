defmodule Gitastic.ChecksTest do
  use ExUnit.Case, async: true

  alias Gitastic.{Checks, GitRepo}

  setup do
    repo = GitRepo.new()
    GitRepo.git!(repo, ["checkout", "-q", "main"])
    dir = Path.join(System.tmp_dir!(), "gitastic-checks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    Phoenix.PubSub.subscribe(Gitastic.PubSub, Checks.topic())
    %{repo: repo, dir: dir, sha: GitRepo.git!(repo, ["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp checks(c, command) do
    name = :"checks_#{System.unique_integer([:positive])}"
    start_supervised!({Checks, name: name, command: command, dir: c.dir, store: nil})
    name
  end

  defp finished(server, sha) do
    assert_receive {:checks, ^sha}, 5_000

    case Checks.status(sha, server) do
      %{} = result -> result
      _ -> finished(server, sha)
    end
  end

  test "runs the command in a checkout of exactly that commit, and keeps the result", c do
    server = checks(c, "git rev-parse HEAD; echo checked")
    Checks.want(c.repo, c.sha, server)

    assert %{ok: true, sha: sha, log: log} = finished(server, c.sha)
    assert sha == c.sha
    assert log =~ c.sha
    assert log =~ "checked"
    assert Checks.log(c.sha, server) =~ "checked"

    # Asked again: already known, not run again.
    Checks.want(c.repo, c.sha, server)
    refute_receive {:checks, _}, 200
  end

  test "a failing command is a failed result, with its output", c do
    server = checks(c, "echo 'test failed: 1 failure'; exit 1")
    Checks.want(c.repo, c.sha, server)

    assert %{ok: false, log: log} = finished(server, c.sha)
    assert log =~ "1 failure"
  end

  test "while one runs, only the newest tip waits; a superseded one is skipped", c do
    server = checks(c, "sleep 0.3; git rev-parse HEAD")
    Checks.want(c.repo, c.sha, server)
    second = GitRepo.commit!(c.repo, %{"a" => "a"}, "Second")
    third = GitRepo.commit!(c.repo, %{"b" => "b"}, "Third")
    Checks.want(c.repo, second, server)
    Checks.want(c.repo, third, server)

    assert {:queued, nil} = Checks.status(third, server)
    assert %{ok: true} = finished(server, c.sha)
    assert %{ok: true, log: log} = finished(server, third)
    assert log =~ third
    assert :none = Checks.status(second, server)
  end

  test "without a command there are no checks", c do
    server = checks(c, nil)
    refute Checks.enabled?(server)
    Checks.want(c.repo, c.sha, server)
    assert :none = Checks.status(c.sha, server)
  end
end
