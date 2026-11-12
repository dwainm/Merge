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

  # Asked, and taken in: the answer is read from the board, not from the process,
  # so a read right behind the request waits for it to land.
  defp want(repo, sha, server) do
    Checks.want(repo, sha, server)
    _ = :sys.get_state(server)
    :ok
  end

  # The topic is one for every test's checks: wait for this server's run to be gone.
  defp cut_off(server, sha) do
    assert_receive {:checks, ^sha}, 5_000

    case Checks.status(sha, server) do
      {:running, _} -> cut_off(server, sha)
      status -> status
    end
  end

  defp finished(server, sha) do
    assert_receive {:checks, ^sha}, 5_000

    case Checks.status(sha, server) do
      %{} = result -> result
      _ -> finished(server, sha)
    end
  end

  test "the state is read while the checks' process is busy", c do
    server = checks(c, "echo checked")
    want(c.repo, c.sha, server)
    assert %{ok: true} = finished(server, c.sha)

    :ok = :sys.suspend(server)
    assert Checks.enabled?(server)
    assert %{ok: true} = Checks.status(c.sha, server)
    assert Checks.image_status(c.sha, server) == :off
    assert Checks.status(String.duplicate("0", 40), server) == :none
    :ok = :sys.resume(server)
  end

  test "a check that is killed was not run, and runs again when asked", c do
    Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
    once = Path.join(c.dir, "once")
    # Killed the first time (as when the server stops under it), fine the second.
    server =
      checks(c, "if [ -f #{once} ]; then echo checked; else touch #{once}; kill -TERM $$; fi")

    want(c.repo, c.sha, server)
    assert cut_off(server, c.sha) == :none
    assert Checks.log(c.sha, server) =~ "Cut off before it ended"

    want(c.repo, c.sha, server)
    assert %{ok: true, log: "checked" <> _} = finished(server, c.sha)
  end

  test "a check that is killed every time fails the second time", c do
    Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
    server = checks(c, "kill -TERM $$")

    want(c.repo, c.sha, server)
    assert cut_off(server, c.sha) == :none

    want(c.repo, c.sha, server)
    assert %{ok: false, log: log} = finished(server, c.sha)
    assert log =~ "Cut off 2 times"
  end

  test "a run whose end never arrived is seen gone on the second look, and runs again", c do
    Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
    go = Path.join(c.dir, "go")
    server = checks(c, "while [ ! -f #{go} ]; do sleep 0.05; done; echo checked")
    want(c.repo, c.sha, server)
    assert {:running, _} = Checks.status(c.sha, server)

    # As when its exit arrived while the code was being loaded: the command is
    # gone and the process never heard.
    gone = Port.open({:spawn, "true"}, [])
    Port.close(gone)
    :sys.replace_state(server, fn state -> put_in(state.running.port, gone) end)

    want(c.repo, c.sha, server)
    assert {:running, _} = Checks.status(c.sha, server)
    File.write!(go, "")
    want(c.repo, c.sha, server)
    assert %{ok: true} = finished(server, c.sha)
    assert Checks.log(c.sha, server) =~ "checked"
  end

  test "runs the command in a checkout of exactly that commit, and keeps the result", c do
    server = checks(c, "git rev-parse HEAD; echo checked")
    want(c.repo, c.sha, server)

    assert %{ok: true, sha: sha, log: log, excerpt: nil} = finished(server, c.sha)
    assert sha == c.sha
    assert log =~ c.sha
    assert log =~ "checked"
    assert Checks.log(c.sha, server) =~ "checked"

    # Asked again: already known, not run again.
    want(c.repo, c.sha, server)
    refute_receive {:checks, _}, 200
  end

  test "a failing command is a failed result, with its output", c do
    server = checks(c, "echo 'test failed: 1 failure'; exit 1")
    want(c.repo, c.sha, server)

    assert %{ok: false, log: log} = finished(server, c.sha)
    assert log =~ "1 failure"
  end

  test "a failed result keeps the step that failed first, read off the whole log", c do
    server =
      checks(
        c,
        "echo Advisories:; echo '  ecto 3.14.2 - EEF-CVE-2026-118391 (HIGH)'; " <>
          "echo 'Found packages with security advisories'; seq 1 200; echo 'Result: 994 passed'; exit 1"
      )

    want(c.repo, c.sha, server)

    assert %{ok: false, log: log, excerpt: excerpt} = finished(server, c.sha)
    refute log =~ "Advisories:"
    assert excerpt =~ ~r/\AAdvisories:.*EEF-CVE-2026-118391.*security advisories\z/s
  end

  test "while one runs, only the newest tip waits; a superseded one is skipped", c do
    server = checks(c, "sleep 0.3; git rev-parse HEAD")
    want(c.repo, c.sha, server)
    second = GitRepo.commit!(c.repo, %{"a" => "a"}, "Second")
    third = GitRepo.commit!(c.repo, %{"b" => "b"}, "Third")
    want(c.repo, second, server)
    want(c.repo, third, server)

    assert {:queued, nil} = Checks.status(third, server)
    assert %{ok: true} = finished(server, c.sha)
    assert %{ok: true, log: log} = finished(server, third)
    assert log =~ third
    assert :none = Checks.status(second, server)
  end

  test "the check a merged merge request shows: its own merge commit's, else main's while not pushed",
       c do
    server = checks(c, "true")
    want(c.repo, c.sha, server)
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
    want(c.repo, c.sha, server)
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
      want(c.repo, tip, server)

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
      want(c.repo, tip, server)

      assert %{ok: true} = finished(server, tip)
      assert :not_needed = Checks.image_status(tip, server)
      assert nil == Checks.image_log(tip, server)
    end

    test "a failed image build is a failed result, with its output", c do
      server = checks(c, "true", "echo 'tailwind fetch failed'; exit 1")
      tip = GitRepo.commit!(c.repo, %{"config/prod.exs" => "x\n"}, "Config")
      want(c.repo, tip, server)

      assert %{ok: false, log: log} = image_finished(server, tip)
      assert log =~ "tailwind fetch failed"
    end

    test "a newer tip waiting when the first check ends skips the old tip's image check", c do
      server = checks(c, "sleep 0.3", "echo built")
      old = GitRepo.commit!(c.repo, %{"Dockerfile" => "FROM a\n"}, "Old")
      want(c.repo, old, server)
      assert {:queued, nil} = Checks.image_status(old, server)
      new = GitRepo.commit!(c.repo, %{"Dockerfile" => "FROM b\n"}, "New")
      want(c.repo, new, server)

      assert %{ok: true} = image_finished(server, new)
      assert :none = Checks.image_status(old, server)
    end

    test "is off without an image command", c do
      server = checks(c, "true")
      assert :off = Checks.image_status("abc", server)
    end
  end

  test "the newest commit's image decision is kept however many came before", c do
    # On 10 Nov 2026 a tip whose sha sorted low ("380b…") lost its "not needed" the moment
    # it was decided, and Auto Push waited on an image build that would never run.
    server = checks(c, "sleep 60", "true")

    for n <- 1..40 do
      sha = GitRepo.commit!(c.repo, %{"N#{n}.md" => "#{n}\n"}, "N#{n}")
      want(c.repo, sha, server)
      assert Checks.image_status(sha, server) == :not_needed
    end
  end
end
