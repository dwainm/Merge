defmodule MergeWeb.LiveStatusLiveTest do
  # The readings are one map on the board: one test at a time.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{GitRepo, LiveStatus, MergeRequest}

  setup do
    branch = "live-page-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Live page"})
    %{branch: branch, repo: repo}
  end

  defp look(c), do: LiveStatus.run(only: [c.branch], listeners: %{})

  test "the list says Ready to review when nothing is in the way", %{conn: conn} = c do
    look(c)
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#live-badge-#{c.branch}", "Ready to review")
    refute has_element?(view, "#live-reasons-#{c.branch}")
  end

  test "the list and the page say what is in the way, and follow a new reading",
       %{conn: conn} = c do
    look(c)
    {:ok, home, _html} = live(conn, ~p"/")
    {:ok, page, _html} = live(conn, MergeWeb.mr_path(c.branch))
    refute has_element?(page, "#live-status")

    File.write!(Path.join(c.repo, "lib/app.ex"), "changed\n")
    File.write!(Path.join(c.repo, ".dev-url"), "https://live.dev.example.com/\n")
    look(c)

    assert has_element?(home, "#live-badge-#{c.branch}", "Being changed")

    assert has_element?(
             home,
             "#live-reasons-#{c.branch} [data-kind=changes]",
             "1 file not committed"
           )

    assert has_element?(
             home,
             "#live-reasons-#{c.branch} [data-kind=site_down]",
             "Test site is down"
           )

    assert has_element?(page, "#live-badge", "Being changed")
    assert has_element?(page, "#live-status [data-kind=changes]")
    # Beside the tree, where the person would tap to test.
    assert has_element?(page, "#test-site-down", "Test site is down")
  end

  test "In progress from the file shows its note", %{conn: conn} = c do
    File.write!(Path.join(c.repo, ".mr.status"), "in progress\nRebuilding the list\n")
    look(c)
    {:ok, page, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(page, "#live-badge", "In progress")
    assert has_element?(page, "#live-status [data-kind=in_progress]", "Rebuilding the list")
  end

  test "the page says what came since the reviewer last looked", %{conn: conn} = c do
    {:ok, page, _html} = live(conn, MergeWeb.mr_path(c.branch))
    refute has_element?(page, "#since-looked")
    # The look is taken as the page opens.
    _ = :sys.get_state(page.pid)
    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    _ = :sys.get_state(pid)

    GitRepo.commit!(c.repo, %{"lib/b.ex" => "b\n"}, "Add the b page")
    :ok = MergeRequest.check_branch(c.branch)

    {:ok, home, _html} = live(conn, ~p"/")
    assert has_element?(home, "#since-looked-#{c.branch}", "1 new commit since you looked")

    {:ok, page, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(page, "#since-looked", "1 new commit since you last looked")
    assert has_element?(page, "#since-looked", "Add the b page")

    page |> element("#since-looked-link") |> render_click()
    assert has_element?(page, "#since-look-tab.bg-\\(--btn-bg\\)")
    assert has_element?(page, "#diff-files", "lib/b.ex")
  end
end
