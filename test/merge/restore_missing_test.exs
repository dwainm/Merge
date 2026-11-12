defmodule Merge.RestoreMissingTest do
  # The store is one for the whole app.
  use ExUnit.Case, async: false

  alias Merge.{GitRepo, MergeRequest}

  setup do
    dir = Path.join(System.tmp_dir!(), "merge-restore-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :store_dir, Path.join(dir, "merge_requests"))

    on_exit(fn ->
      Application.delete_env(:merge, :store_dir)
      File.rm_rf!(dir)
    end)

    branch = "restore-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)
    %{branch: branch, repo: repo}
  end

  test "a merge request whose process died comes back from its file", %{branch: branch} = c do
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: c.repo, opened_by: "agent"})
    {:ok, _} = MergeRequest.comment(branch, %{body: "Why empty?"})
    {:ok, before} = MergeRequest.get(branch)

    # As a code reload does: the process is gone, its file stays.
    [{pid, _}] = Registry.lookup(Merge.Registry, branch)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # The registry lets go of the name when it hears of the exit.
    _ = :sys.get_state(Merge.Registry.PIDPartition0)
    # Pages still read it as it was (a reload no longer empties the list);
    # nothing can be added until it is back.
    assert MergeRequest.get(branch) == {:ok, before}
    assert Enum.any?(MergeRequest.list(), &(&1.branch == branch))
    assert MergeRequest.comment(branch, %{body: "Anyone there?"}) == :error

    assert MergeRequest.restore_missing() >= 1
    assert {:ok, mr} = MergeRequest.get(branch)
    assert [%{body: "Why empty?"}] = mr.comments
    assert Map.delete(mr, :waiting) == Map.delete(before, :waiting)

    # Running ones are left as they are.
    assert MergeRequest.restore_missing() == 0
  end

  test "opening a branch whose process died brings it back, comments and all", c do
    {:ok, _, :opened} = MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent"})
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Why empty?"})

    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _ = :sys.get_state(Merge.Registry.PIDPartition0)

    assert {:ok, mr, :existing} =
             MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent"})

    assert [%{body: "Why empty?"}] = mr.comments
  end

  test "the watcher sets its next round from any message, not only from a round" do
    pid = Process.whereis(Merge.Watcher)
    timer = fn -> pid |> Process.info(:dictionary) |> elem(1) |> Keyword.get(:round_timer) end
    # Off in tests: no rounds, no timer.
    assert timer.() == nil

    Application.put_env(:merge, :watch_ms, 3_600_000)

    on_exit(fn ->
      Application.delete_env(:merge, :watch_ms)
      if ref = timer.(), do: Process.cancel_timer(ref)
      :sys.replace_state(pid, fn state -> Process.delete(:round_timer) && state end)
    end)

    # As after a tick was dropped: nothing set, and an approval's message arrives.
    Merge.Watcher.schedule_auto_push()
    _ = :sys.get_state(pid)
    assert is_integer(Process.read_timer(timer.()))
  end
end
