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
    assert MergeRequest.get(branch) == :error

    assert MergeRequest.restore_missing() >= 1
    assert {:ok, mr} = MergeRequest.get(branch)
    assert [%{body: "Why empty?"}] = mr.comments
    assert Map.delete(mr, :waiting) == Map.delete(before, :waiting)

    # Running ones are left as they are.
    assert MergeRequest.restore_missing() == 0
  end
end
