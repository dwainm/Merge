defmodule Merge.AutoPushTest do
  # The toggle and the clock are kept in the store, which is one for the whole app.
  use ExUnit.Case, async: false

  alias Merge.{AutoPush, Drift, Events, GitRepo}

  @period 20 * 60_000

  setup do
    dir = Path.join(System.tmp_dir!(), "merge-auto-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :store_dir, Path.join(dir, "merge_requests"))
    Application.put_env(:merge, :auto_push_ms, @period)
    Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())

    on_exit(fn ->
      Application.delete_env(:merge, :store_dir)
      Application.delete_env(:merge, :auto_push_ms)
      File.rm_rf!(dir)
    end)

    {repo, origin} = GitRepo.with_origin()
    tip = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    %{repo: repo, origin: origin, tip: tip, t0: ~U[2026-11-10 10:00:00Z]}
  end

  defp later(t, minutes), do: DateTime.add(t, minutes * 60, :second)

  # The checks as Merge.Checks gives them, for `tip`.
  defp passed(tip), do: [checks_on: true, checks: %{sha: tip, ok: true}, image: :not_needed]

  defp origin_main(origin), do: origin |> GitRepo.git!(["rev-parse", "main"]) |> String.trim()

  # The clock starts when the tip is first seen (a refresh); the toggle went on before it.
  defp on_and_seen(tip, t0) do
    :ok = AutoPush.set(true, later(t0, -60))
    AutoPush.see_tip(tip, t0)
  end

  test "is off until someone turns it on, and does not push while off",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    before = origin_main(origin)
    refute AutoPush.on?()
    AutoPush.see_tip(tip, t0)

    assert AutoPush.run(repo, later(t0, 60), passed(tip)) == :off
    assert origin_main(origin) == before
  end

  test "with no store it stays off", %{repo: repo, tip: tip, t0: t0} do
    Application.put_env(:merge, :store_dir, nil)
    assert AutoPush.set(true) == :error
    refute AutoPush.on?()
    assert AutoPush.run(repo, later(t0, 60), passed(tip)) == :off
  end

  test "does not push before the period is up", %{repo: repo, origin: origin, tip: tip, t0: t0} do
    before = origin_main(origin)
    on_and_seen(tip, t0)

    due = later(t0, 20)
    assert AutoPush.run(repo, later(t0, 19), passed(tip)) == {:due, due}
    assert AutoPush.text({:due, due}) == "Pushes itself at 12:20"
    assert origin_main(origin) == before
  end

  test "does not push on failed or running checks, or a failed image build",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    before = origin_main(origin)
    on_and_seen(tip, t0)
    at = later(t0, 30)
    failed = [checks_on: true, checks: %{sha: tip, ok: false}, image: :not_needed]
    running = [checks_on: true, checks: {:running, t0}, image: :off]
    image_failed = [checks_on: true, checks: %{sha: tip, ok: true}, image: %{sha: tip, ok: false}]
    image_running = [checks_on: true, checks: %{sha: tip, ok: true}, image: {:running, t0}]
    other_sha = [checks_on: true, checks: %{sha: "0000000", ok: true}, image: :off]

    assert AutoPush.run(repo, at, failed) == {:hold, "checks failed: not pushing"}
    assert {:wait, "checks running", _} = AutoPush.run(repo, at, running)
    assert {:wait, "checks haven't run yet", _} = AutoPush.run(repo, at, other_sha)
    assert AutoPush.run(repo, at, image_failed) == {:hold, "image build failed: not pushing"}
    assert {:wait, "image build running", _} = AutoPush.run(repo, at, image_running)
    assert {:hold, "no checks are set up: not pushing"} = AutoPush.run(repo, at, checks_on: false)
    assert origin_main(origin) == before
  end

  test "does not push when GitHub has commits main hasn't",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    # Someone pushed to GitHub from another clone.
    other = Path.join(Path.dirname(origin), "other")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, other], stderr_to_stdout: true)
    GitRepo.commit!(other, %{"THEIRS.md" => "x\n"}, "Theirs")
    GitRepo.git!(other, ["push", "-q", "origin", "main"])
    theirs = origin_main(origin)
    Merge.Git.fetch(repo)

    on_and_seen(tip, t0)

    assert AutoPush.run(repo, later(t0, 30), passed(tip)) ==
             {:hold, "GitHub has commits you don't: not pushing"}

    assert origin_main(origin) == theirs
  end

  test "a new tip starts the period again", %{repo: repo, origin: origin, tip: tip, t0: t0} do
    before = origin_main(origin)
    on_and_seen(tip, t0)

    # Main moved at minute 19, one minute before the first tip was due.
    new = GitRepo.commit!(repo, %{"TWO.md" => "2\n"}, "Two")
    AutoPush.see_tip(new, later(t0, 19))

    assert AutoPush.run(repo, later(t0, 25), passed(new)) == {:due, later(t0, 39)}
    # The old tip's passed checks don't speak for the new one.
    assert {:wait, "checks haven't run yet", _} = AutoPush.run(repo, later(t0, 45), passed(tip))
    assert origin_main(origin) == before
  end

  test "turning it on starts the period from then, when main has been still longer",
       %{repo: repo, tip: tip, t0: t0} do
    AutoPush.see_tip(tip, t0)
    :ok = AutoPush.set(true, later(t0, 60))
    assert AutoPush.run(repo, later(t0, 70), passed(tip)) == {:due, later(t0, 80)}
  end

  test "pushes once when all hold, and says it was the timer",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    on_and_seen(tip, t0)

    assert %{ok: true, tip: ^tip} = AutoPush.run(repo, later(t0, 20), passed(tip))
    assert origin_main(origin) == tip
    short = Events.short(tip)
    events = events()
    assert Enum.any?(events, &(&1 =~ " auto-push-on main"))
    assert Enum.any?(events, &(&1 =~ " pushed main 1 commits, origin at #{short}"))
    assert Enum.any?(events, &(&1 =~ " auto-pushed main 1 commits, origin at #{short}"))

    assert AutoPush.run(repo, later(t0, 21), passed(tip)) == :even
    refute Enum.any?(events(), &(&1 =~ "pushed"))
  end

  defp events do
    receive do
      {:event, line} -> [line | events()]
    after
      0 -> []
    end
  end

  test "a failed push is not tried again until a new tip",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    # GitHub refuses the push itself (the dry run still lands).
    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho refused by the test >&2\nexit 1\n")
    File.chmod!(hook, 0o755)
    before = origin_main(origin)
    on_and_seen(tip, t0)

    assert %{ok: false} = AutoPush.run(repo, later(t0, 20), passed(tip))
    assert {:hold, "push failed: " <> _} = AutoPush.run(repo, later(t0, 21), passed(tip))
    assert {:hold, _} = AutoPush.run(repo, later(t0, 90), passed(tip))
    assert origin_main(origin) == before

    File.rm!(hook)
    new = GitRepo.commit!(repo, %{"TWO.md" => "2\n"}, "Two")
    AutoPush.see_tip(new, later(t0, 91))
    assert %{ok: true, tip: ^new} = AutoPush.run(repo, later(t0, 111), passed(new))
    assert origin_main(origin) == new
  end

  test "a push by hand after a failed one lets it try again",
       %{repo: repo, origin: origin, tip: tip, t0: t0} do
    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    on_and_seen(tip, t0)

    assert %{ok: false} = AutoPush.run(repo, later(t0, 20), passed(tip))
    # A hand push, also refused: the auto-push may try once more.
    assert %{ok: false} = Drift.push(repo, tip)
    File.rm!(hook)
    assert %{ok: true} = AutoPush.run(repo, later(t0, 22), passed(tip))
  end

  test "the period is 5 minutes unless the flag says otherwise" do
    Application.delete_env(:merge, :auto_push_ms)
    assert AutoPush.period_ms() == 5 * 60_000
    assert AutoPush.period_text() == "5 minutes"
  end

  test "the period reads like the flag" do
    assert AutoPush.parse_period("20m") == {:ok, 20 * 60_000}
    assert AutoPush.parse_period("1m") == {:ok, 60_000}
    assert AutoPush.parse_period("90s") == {:ok, 90_000}
    assert AutoPush.parse_period("1h") == {:ok, 3_600_000}
    assert AutoPush.parse_period("15") == {:ok, 15 * 60_000}
    assert AutoPush.parse_period("0m") == :error
    assert AutoPush.parse_period("soon") == :error
  end
end
