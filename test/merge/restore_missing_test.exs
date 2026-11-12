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
    # Pages still read it as it was (a reload no longer empties the list).
    assert MergeRequest.get(branch) == {:ok, before}
    assert Enum.any?(MergeRequest.list(), &(&1.branch == branch))

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

  test "a command for one whose process died starts it from its file", c do
    {:ok, _, :opened} = MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent"})
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Why empty?"})

    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _ = :sys.get_state(Merge.Registry.PIDPartition0)

    assert {:ok, %{id: 2}} = MergeRequest.comment(c.branch, %{body: "And this?"})

    assert {:ok, %{comments: [%{body: "Why empty?"}, %{body: "And this?"}]}} =
             MergeRequest.get(c.branch)
  end

  describe "a finished merge request rests" do
    setup c do
      {:ok, _, :opened} = MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent"})
      {:ok, _} = MergeRequest.comment(c.branch, %{body: "Why empty?"})
      {:ok, :closed} = MergeRequest.close(c.branch)
      {:ok, awake} = MergeRequest.get(c.branch)
      [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
      ref = Process.monitor(pid)
      assert MergeRequest.rest_settled() >= 1
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :rest}}
      %{awake: awake}
    end

    test "with no process, still listed, and its page still has the diff", c do
      assert Registry.lookup(Merge.Registry, c.branch) == []

      assert [%{status: :closed, files: [], file_count: 1}] =
               Enum.filter(MergeRequest.list(), &(&1.branch == c.branch))

      assert Merge.Board.get(c.branch) == nil
      assert MergeRequest.get(c.branch) == {:ok, c.awake}
      assert {:ok, %{files: [%{path: "lib/app.ex"}], comments: [_]}} = MergeRequest.get(c.branch)
      # Reading it started nothing, and neither does a round.
      assert MergeRequest.restore_missing() == 0
      assert MergeRequest.check_branch(c.branch) == :error
      assert Registry.lookup(Merge.Registry, c.branch) == []
    end

    test "a wait on it is answered, and it rests again", c do
      assert {:ok, %{kind: :closed, status: :closed}} = MergeRequest.wait(c.branch, "agent", 50)
      assert [{_pid, _}] = Registry.lookup(Merge.Registry, c.branch)
      assert MergeRequest.rest_settled() >= 1
      assert MergeRequest.get(c.branch) == {:ok, c.awake}
    end

    test "opening the branch again makes a new one in its place", c do
      assert {:ok, mr, :opened} =
               MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent-b"})

      assert %{status: :open, comments: [], opened_by: "agent-b"} = mr
      assert [%{status: :open}] = Enum.filter(MergeRequest.list(), &(&1.branch == c.branch))
    end

    test "after a restart it is listed from its file, with no process", c do
      Merge.Board.delete(c.branch)
      MergeRequest.restore_all()
      assert Registry.lookup(Merge.Registry, c.branch) == []

      assert [%{status: :closed, file_count: 1}] =
               Enum.filter(MergeRequest.list(), &(&1.branch == c.branch))

      assert MergeRequest.get(c.branch) == {:ok, c.awake}
    end
  end

  test "one that is in review, or has someone waiting, does not rest", c do
    {:ok, _, :opened} = MergeRequest.open(%{branch: c.branch, repo: c.repo, opened_by: "agent"})
    MergeRequest.rest_settled()
    assert [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    assert Process.alive?(pid)
  end

  test "where the rounds run by themselves, a round leaves the network to the workers" do
    Phoenix.PubSub.subscribe(Merge.PubSub, Merge.Servers.topic())
    Application.put_env(:merge, :watch_ms, 3_600_000)
    on_exit(fn -> Application.delete_env(:merge, :watch_ms) end)

    assert Merge.Background.on?()
    Merge.Watcher.run()
    # The trees and servers come from the prober, in its own process.
    assert_receive {:servers, _}, 5_000
    assert is_pid(Process.whereis(Merge.Prober))
    assert is_pid(Process.whereis(Merge.Fetcher))
    _ = :sys.get_state(Merge.Prober)
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
