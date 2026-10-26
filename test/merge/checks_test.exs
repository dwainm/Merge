defmodule Merge.ChecksTest do
  use ExUnit.Case, async: true

  alias Merge.{Checks, GitRepo}

  setup do
    repo = GitRepo.new()
    GitRepo.git!(repo, ["checkout", "-q", "main"])
    dir = Path.join(System.tmp_dir!(), "merge-checks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
    %{repo: repo, dir: dir, sha: GitRepo.git!(repo, ["rev-parse", "HEAD"]) |> String.trim()}
  end

  defp checks(c, command, image \\ nil) do
    name = :"checks_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Checks, name: name, command: command, image_command: image, dir: c.dir, store: nil}
    )

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

  test "the check a merged merge request shows: its own merge commit's, else main's while not pushed",
       c do
    server = checks(c, "true")
    Checks.want(c.repo, c.sha, server)
    assert %{ok: true} = finished(server, c.sha)
    tip = GitRepo.commit!(c.repo, %{"a" => "a"}, "Later merge")

    # Its merge commit was checked: that result.
    own = %{merged: %{sha: c.sha, pushed: true}}
    assert {sha, %{ok: true}} = Checks.for_merge_request(own, tip, server)
    assert sha == c.sha

    # Merged in the same batch, not checked itself, not pushed: main's tip speaks for it.
    batch = %{merged: %{sha: "0000000", pushed: false}}
    assert {^tip, :none} = Checks.for_merge_request(batch, tip, server)

    # Long on origin with no result of its own: no pill.
    assert nil ==
             Checks.for_merge_request(%{merged: %{sha: "0000000", pushed: true}}, tip, server)

    assert nil == Checks.for_merge_request(%{merged: nil}, tip, server)
  end

  test "without a command there are no checks", c do
    server = checks(c, nil)
    refute Checks.enabled?(server)
    Checks.want(c.repo, c.sha, server)
    assert :none = Checks.status(c.sha, server)
  end

  describe "the image check" do
    @workflow """
    on:
      pull_request:
        paths:
          - "Dockerfile"
          - "config/**"
    """

    setup c do
      {repo, _origin} = GitRepo.with_origin()
      GitRepo.commit!(repo, %{".github/workflows/docker.yml" => @workflow}, "Workflow")
      GitRepo.git!(repo, ["push", "-q", "origin", "main"])
      %{c | repo: repo}
    end

    defp image_finished(server, sha) do
      assert_receive {:checks, ^sha}, 5_000

      case Checks.image_status(sha, server) do
        %{} = result -> result
        _ -> image_finished(server, sha)
      end
    end

    test "runs after the first, in the same checkout, when the tip changes a watched path", c do
      server = checks(c, "echo first > ../order", "cat ../order; git rev-parse HEAD; echo built")
      tip = GitRepo.commit!(c.repo, %{"Dockerfile" => "FROM elixir\n"}, "Image")
      Checks.want(c.repo, tip, server)

      assert %{ok: true} = finished(server, tip)
      assert %{ok: true, log: log} = image_finished(server, tip)
      assert log =~ "first"
      assert log =~ tip
      assert Checks.image_log(tip, server) =~ "built"
      refute Checks.log(tip, server) =~ "built"
    end

    test "is not needed when the tip changes nothing the workflow watches", c do
      server = checks(c, "true", "echo built")
      tip = GitRepo.commit!(c.repo, %{"lib/app.ex" => "x\n"}, "Code")
      Checks.want(c.repo, tip, server)

      assert %{ok: true} = finished(server, tip)
      assert :not_needed = Checks.image_status(tip, server)
      assert nil == Checks.image_log(tip, server)
    end

    test "a failed image build is a failed result, with its output", c do
      server = checks(c, "true", "echo 'tailwind fetch failed'; exit 1")
      tip = GitRepo.commit!(c.repo, %{"config/prod.exs" => "x\n"}, "Config")
      Checks.want(c.repo, tip, server)

      assert %{ok: false, log: log} = image_finished(server, tip)
      assert log =~ "tailwind fetch failed"
    end

    test "a newer tip waiting when the first check ends skips the old tip's image check", c do
      server = checks(c, "sleep 0.3", "echo built")
      old = GitRepo.commit!(c.repo, %{"Dockerfile" => "FROM a\n"}, "Old")
      Checks.want(c.repo, old, server)
      assert {:queued, nil} = Checks.image_status(old, server)
      new = GitRepo.commit!(c.repo, %{"Dockerfile" => "FROM b\n"}, "New")
      Checks.want(c.repo, new, server)

      assert %{ok: true} = image_finished(server, new)
      assert :none = Checks.image_status(old, server)
    end

    test "is off without an image command", c do
      server = checks(c, "true")
      assert :off = Checks.image_status("abc", server)
    end
  end
end
