defmodule Merge.StoreTest do
  # Not async: it points the store at a directory of its own for the whole app.
  use ExUnit.Case, async: false

  alias Merge.{GitRepo, MergeRequest}

  setup do
    dir = Path.join(System.tmp_dir!(), "merge-store-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :store_dir, dir)

    on_exit(fn ->
      Application.delete_env(:merge, :store_dir)
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "a restart keeps a merge request, with its comments, decisions and notes" do
    branch = "store-test/#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)

    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, opened_by: "agent-a"})
    {:ok, _} = MergeRequest.comment(branch, %{body: "Why empty?", path: "lib/app.ex", line: 2})
    {:ok, _} = MergeRequest.decide(branch, :needs_work, "Keep hello.")
    sha = GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")
    {:ok, _} = MergeRequest.addressed(branch, sha, "Added a readme")
    {:ok, before} = MergeRequest.get(branch)

    # The server stops: the process is gone.
    [{pid, _}] = Registry.lookup(Merge.Registry, branch)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Merge.MergeRequests, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert :error = MergeRequest.get(branch)

    # It starts again.
    assert MergeRequest.restore_all() >= 1
    assert {:ok, after_restart} = MergeRequest.get(branch)
    assert after_restart == before

    assert %{
             comments: [%{body: "Why empty?", path: "lib/app.ex", line: 2}],
             decisions: [%{verdict: :needs_work, body: "Keep hello."}],
             addressed: [%{sha: ^sha, note: "Added a readme"}],
             head: ^sha
           } = after_restart

    # And it carries on: a decision still reaches a waiting agent.
    {:ok, _} = MergeRequest.decide(branch, :approved)
    assert {:ok, %{status: :approved}} = MergeRequest.wait(branch, "agent-a", 1_000)
  end

  test "one saved before comments were numbered comes back where the old rule left each agent" do
    branch = "store-old/#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)

    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, opened_by: "agent-a"})
    {:ok, _} = MergeRequest.comment(branch, %{body: "Why empty?"})
    {:ok, _} = MergeRequest.decide(branch, :needs_work, "Keep hello.")

    # Rewrite the file the way the previous version saved it.
    [{pid, _}] = Registry.lookup(Merge.Registry, branch)
    {:ok, mr} = MergeRequest.get(branch)
    :ok = DynamicSupervisor.terminate_child(Merge.MergeRequests, pid)

    old =
      mr
      |> Map.drop([:seq, :cursors, :waiting])
      |> Map.update!(:comments, fn cs -> Enum.map(cs, &Map.delete(&1, :seq)) end)
      |> Map.update!(:decisions, fn ds -> Enum.map(ds, &Map.delete(&1, :seq)) end)

    Merge.Store.put(old)
    MergeRequest.restore_all()

    # The decision wasn't addressed, so agent-a hears it, with its round's comment, once.
    assert {:ok, %{kind: :decision, comments: [%{body: "Why empty?"}]}} =
             MergeRequest.wait(branch, "agent-a", 1_000)

    assert {:ok, :timeout} = MergeRequest.wait(branch, "agent-a", 50)
  end
end
