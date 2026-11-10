defmodule MergeWeb.AutoMergeLineTest do
  # Auto Merge is on here, and looks at every merge request: none may run beside it.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{AutoMerge, GitRepo, MergeRequest}

  setup do
    Application.put_env(:merge, :auto_merge, true)
    :persistent_term.erase({AutoMerge, :holds})
    {main, _origin} = GitRepo.with_origin()
    GitRepo.git!(main, ["config", "user.name", "Merge"])
    GitRepo.git!(main, ["config", "user.email", "merge@example.com"])
    branch = "am-line-#{System.unique_integer([:positive])}"
    feature = main <> "-#{branch}"
    GitRepo.git!(main, ["worktree", "add", "-q", "-b", branch, feature])
    GitRepo.commit!(feature, %{"lib/feature.ex" => "defmodule Feature do\nend\n"}, "Feature")

    on_exit(fn ->
      Application.put_env(:merge, :auto_merge, false)
      if pid = Process.whereis(Merge.Watcher), do: _ = :sys.get_state(pid)
      MergeRequest.close(branch)
      File.rm_rf!(feature)
    end)

    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: feature})
    %{main: main, branch: branch}
  end

  test "an approved request that is held says why, on the home page and its own",
       %{conn: conn, main: main, branch: branch} do
    File.write!(Path.join(main, "lib/app.ex"), "defmodule App do\n  # mid-edit\nend\n")
    {:ok, _} = MergeRequest.decide(branch, :approved)
    _ = :sys.get_state(Merge.Watcher)

    {:ok, home, _} = live(conn, ~p"/")
    line = "#auto-merge-#{branch}"
    assert has_element?(home, line, "Not merging:")
    assert has_element?(home, line, "Main's worktree has uncommitted changes")

    {:ok, page, _} = live(conn, MergeWeb.mr_path(branch))
    assert has_element?(page, line, "Main's worktree has uncommitted changes")

    # Once it's free, it goes, and the page says merged.
    GitRepo.git!(main, ["checkout", "--", "lib/app.ex"])
    AutoMerge.run(branch)
    refute has_element?(page, line)
    assert {:ok, %{status: :merged}} = MergeRequest.get(branch)
  end
end
