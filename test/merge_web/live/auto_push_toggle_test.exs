defmodule MergeWeb.AutoPushToggleTest do
  # The drift and the toggle are one for the whole server.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{AutoPush, Drift, GitRepo}

  setup do
    dir = Path.join(System.tmp_dir!(), "merge-auto-live-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :store_dir, Path.join(dir, "merge_requests"))
    {repo, origin} = GitRepo.with_origin()
    was = Application.get_env(:merge, :repo)
    Application.put_env(:merge, :repo, repo)
    Drift.put_current(nil)

    on_exit(fn ->
      Application.put_env(:merge, :repo, was)
      Application.delete_env(:merge, :store_dir)
      Drift.put_current(nil)
      if pid = Process.whereis(Merge.Watcher), do: _ = :sys.get_state(pid)
      File.rm_rf!(dir)
    end)

    GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    %{repo: repo, origin: origin}
  end

  test "Auto Push is off until it's turned on, then says what holds it", %{conn: conn, repo: repo} do
    Drift.refresh(repo)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#auto-push-toggle[aria-checked=false]")
    assert has_element?(view, "#auto-push-status", "Auto Push off")

    view |> element("#auto-push-toggle") |> render_click()
    assert AutoPush.on?()
    assert has_element?(view, "#auto-push-toggle[aria-checked=true]")
    # The tests' server runs no checks: nothing is proven, so nothing goes.
    assert has_element?(view, "#auto-push-status", "Auto Push: held")

    view |> element("#auto-push-toggle") |> render_click()
    refute AutoPush.on?()
    assert has_element?(view, "#auto-push-status", "Auto Push off")
  end

  test "without a store the toggle stays off", %{conn: conn} do
    Application.put_env(:merge, :store_dir, nil)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#auto-push-toggle") |> render_click()
    refute AutoPush.on?()
    assert has_element?(view, "#auto-push-toggle[aria-checked=false]")
  end
end
