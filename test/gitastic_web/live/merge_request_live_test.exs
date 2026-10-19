defmodule GitasticWeb.MergeRequestLiveTest do
  use GitasticWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Gitastic.{GitRepo, MergeRequest}

  setup do
    branch = "live-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    first = GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Empty it"})
    %{branch: branch, repo: repo, first: first}
  end

  test "the home page lists open merge requests, and closed ones at the bottom",
       %{conn: conn} = c do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#merge-requests #mr-#{c.branch}", "Empty it")

    MergeRequest.close(c.branch)
    refute has_element?(view, "#merge-requests #mr-#{c.branch}")
    assert has_element?(view, "#done-merge-requests #mr-#{c.branch}", "Closed")

    {:ok, page, _html} = live(conn, GitasticWeb.mr_path(c.branch))
    assert has_element?(page, "#done-banner")
    assert has_element?(page, "#file-0")
    refute has_element?(page, "#decision-form")
  end

  test "the diff, the commits, and one commit alone", %{conn: conn} = c do
    second = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    {:ok, _} = MergeRequest.addressed(c.branch, second)

    {:ok, view, _html} = live(conn, GitasticWeb.mr_path(c.branch))
    assert has_element?(view, "#file-0", "README.md")
    assert has_element?(view, "#file-1", "lib/app.ex")
    assert has_element?(view, "#commits li:first-child", "Add a readme")

    view |> element("#commit-#{String.slice(c.first, 0, 7)} a") |> render_click()
    assert has_element?(view, "#selected-commit", "Empty the app")
    assert has_element?(view, "#file-0", "lib/app.ex")
    refute has_element?(view, "#file-1")
  end

  test "comment on a line, reject, and the agent is told", %{conn: conn} = c do
    waiter = Task.async(fn -> MergeRequest.wait(c.branch, "agent", 5_000) end)
    {:ok, view, _html} = live(conn, GitasticWeb.mr_path(c.branch))

    view
    |> element("#file-0 td[phx-value-side=old][phx-value-line='2']:first-child")
    |> render_click()

    view |> form("#line-comment-form", line: %{body: "Why?"}) |> render_submit()

    view
    |> form("#decision-form", decision: %{body: "Keep hello."})
    |> render_submit(%{verdict: "reject"})

    assert {:ok, %{status: :needs_work, comments: [%{body: "Why?", line: 2, side: "old"}]}} =
             Task.await(waiter)

    assert has_element?(view, "#decision-0", "Needs work")
    assert has_element?(view, "#file-0", "Why?")
  end

  test "rejecting without a word is refused", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, GitasticWeb.mr_path(c.branch))

    view |> form("#decision-form", decision: %{body: ""}) |> render_submit(%{verdict: "reject"})

    assert {:ok, %{decisions: []}} = MergeRequest.get(c.branch)
  end

  test "after a review, the page shows what is new when a commit is addressed",
       %{conn: conn} = c do
    {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "Add a readme.")
    {:ok, view, _html} = live(conn, GitasticWeb.mr_path(c.branch))
    refute has_element?(view, "#since-review")

    sha = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    {:ok, _} = MergeRequest.addressed(c.branch, sha, "Added it")

    assert has_element?(view, "#commit-#{String.slice(sha, 0, 7)}", "new")
    assert has_element?(view, "#addressed-#{String.slice(sha, 0, 7)}", "Added it")
    view |> element("#since-review a") |> render_click()
    assert has_element?(view, "#file-0", "README.md")
    refute has_element?(view, "#file-1")
  end
end
