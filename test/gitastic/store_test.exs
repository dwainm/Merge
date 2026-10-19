defmodule Gitastic.StoreTest do
  # Not async: it points the store at a directory of its own for the whole app.
  use ExUnit.Case, async: false

  alias Gitastic.{GitRepo, MergeRequest}

  setup do
    dir = Path.join(System.tmp_dir!(), "gitastic-store-#{System.unique_integer([:positive])}")
    Application.put_env(:gitastic, :store_dir, dir)

    on_exit(fn ->
      Application.delete_env(:gitastic, :store_dir)
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
    [{pid, _}] = Registry.lookup(Gitastic.Registry, branch)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Gitastic.MergeRequests, pid)
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
end
