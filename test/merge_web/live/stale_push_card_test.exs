defmodule MergeWeb.StalePushCardTest do
  # The drift and the last push are one for the whole server.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{Drift, GitRepo, Store}

  setup do
    {repo, _origin} = GitRepo.with_origin()
    dir = Path.join(System.tmp_dir!(), "merge-store-#{System.unique_integer([:positive])}")
    was = Application.get_env(:merge, :repo)
    Application.put_env(:merge, :repo, repo)
    Application.put_env(:merge, :store_dir, Path.join(dir, "merge_requests"))
    Drift.put_current(nil)

    on_exit(fn ->
      Application.put_env(:merge, :repo, was)
      Application.delete_env(:merge, :store_dir)
      Drift.put_current(nil)
      if pid = Process.whereis(Merge.Watcher), do: _ = :sys.get_state(pid)
      File.rm_rf!(dir)
    end)

    %{repo: repo}
  end

  test "a failed push's card stays until its commits are on GitHub, then goes",
       %{conn: conn, repo: repo} do
    tip = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")

    Store.put_named("last_push", %{
      ok: false,
      pushed: false,
      commits: [],
      to: "main",
      tip: tip,
      origin: nil,
      identical: false,
      left: [],
      output: "Permission denied (publickey).",
      github: nil,
      at: DateTime.utc_now()
    })

    {:ok, view, _html} = live(conn, ~p"/")
    Drift.refresh(repo)
    assert has_element?(view, "#push-result")

    # Pushed from a terminal, not through Merge.
    GitRepo.git!(repo, ["push", "-q", "origin", "main"])
    Drift.refresh(repo)
    refute has_element?(view, "#push-result")
  end
end
