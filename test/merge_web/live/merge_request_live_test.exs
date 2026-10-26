defmodule MergeWeb.MergeRequestLiveTest do
  use MergeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Merge.{GitRepo, MergeRequest}

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

    {:ok, page, _html} = live(conn, MergeWeb.mr_path(c.branch))
    assert has_element?(page, "#done-banner")
    assert has_element?(page, "#file-0")
    refute has_element?(page, "#review-bar")
  end

  test "the diff, the commits, and one commit alone", %{conn: conn} = c do
    second = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")
    {:ok, _} = MergeRequest.addressed(c.branch, second)

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    # No stack known: by top directory, the root's files last, each a group.
    assert has_element?(view, "#group-0 > summary", "lib")
    assert has_element?(view, "#group-0 #file-0", "lib/app.ex")
    assert has_element?(view, "#group-1 > summary", "Top level")
    assert has_element?(view, "#group-1 #file-1", "README.md")
    assert has_element?(view, "#outline a[href='#file-1']", "README.md")
    assert has_element?(view, "#commits li:first-child", "Add a readme")

    view |> element("#commit-#{String.slice(c.first, 0, 7)} a") |> render_click()
    assert has_element?(view, "#selected-commit", "Empty the app")
    assert has_element?(view, "#file-0", "lib/app.ex")
    refute has_element?(view, "#file-1")
    # One group has nothing to tell apart: no heading, no outline.
    refute has_element?(view, "#group-0")
    refute has_element?(view, "#outline")
  end

  test "the author's groups head the page, from the body or from addressed", %{conn: conn} = c do
    body = """
    Empties the app.

    ```groups
    The app, emptied
    Nothing is left of it.
    lib/app.ex
    ```
    """

    {:ok, mr, :existing} = MergeRequest.open(%{branch: c.branch, repo: c.repo, body: body})
    assert mr.groups == "The app, emptied\nNothing is left of it.\nlib/app.ex"
    # The body keeps the block out of the page's text.
    assert mr.body == ""

    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
    refute has_element?(view, "#group-0")

    sha = GitRepo.commit!(c.repo, %{"README.md" => "# App\n"}, "Add a readme")

    {:ok, _} =
      MergeRequest.addressed(c.branch, sha, "Added it", "agent", "The readme\nREADME.md\n")

    assert has_element?(view, "#group-0 > summary", "The readme")
    assert has_element?(view, "#group-0 #file-0", "README.md")
    assert has_element?(view, "#group-1 > summary", "lib")
  end

  test "comment on a line, reject, and the agent is told", %{conn: conn} = c do
    waiter = Task.async(fn -> MergeRequest.wait(c.branch, "agent", 5_000) end)
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    view
    |> element("#file-0 td[phx-value-side=old][phx-value-line='2']:first-child")
    |> render_click()

    view |> form("#line-comment-form", line: %{body: "Why?"}) |> render_submit()

    assert {:ok, %{kind: :comment, comments: [%{body: "Why?", line: 2, side: "old"}]}} =
             Task.await(waiter)

    view |> element("#reject-button") |> render_click()
    view |> form("#reject-form", review: %{body: "Keep hello."}) |> render_submit()

    assert {:ok, %{kind: :decision, decision: %{verdict: :needs_work}, comments: []}} =
             MergeRequest.wait(c.branch, "agent", 5_000)

    # The page empties the box and scrolls to the decision.
    assert_push_event(view, "review-sent", %{to: "decision-0"})

    assert has_element?(view, "#decision-0", "Needs work")
    assert has_element?(view, "#file-0", "Why?")
  end

  test "the bar has three plain actions and no open box", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    assert has_element?(view, "#review-bar #comment-button")
    assert has_element?(view, "#review-bar #approve-button")
    assert has_element?(view, "#review-bar #reject-button")
    refute has_element?(view, "textarea#review-body")
  end

  test "Comment opens a box; sending lands it in the round and closes it", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    view |> element("#comment-button") |> render_click()
    assert has_element?(view, "#comment-dialog #review-body")

    view |> form("#comment-form", review: %{body: "Looks close."}) |> render_submit()

    assert {:ok, %{comments: [%{body: "Looks close.", round: 0, path: nil}], decisions: []}} =
             MergeRequest.get(c.branch)

    refute has_element?(view, "#comment-dialog")
    assert_push_event(view, "review-sent", %{to: "comment-" <> _})
  end

  test "closing the comment box sends nothing and keeps the draft", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    view |> element("#comment-button") |> render_click()
    view |> form("#comment-form", review: %{body: "Half a thought"}) |> render_change()
    view |> render_hook("close_dialog", %{})
    refute has_element?(view, "#comment-dialog")
    assert {:ok, %{comments: []}} = MergeRequest.get(c.branch)

    view |> element("#comment-button") |> render_click()
    assert has_element?(view, "#comment-dialog #review-body", "Half a thought")
  end

  test "Approve asks first, and an approval carries no note", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    # A change request typed into Comment, then a slip onto Approve.
    view |> element("#comment-button") |> render_click()
    view |> form("#comment-form", review: %{body: "The experience is wrong"}) |> render_change()
    view |> render_hook("close_dialog", %{})
    view |> element("#approve-button") |> render_click()

    assert has_element?(view, "#approve-dialog", "Approve Empty it?")
    refute has_element?(view, "#approve-dialog textarea")
    assert {:ok, %{decisions: []}} = MergeRequest.get(c.branch)

    view |> element("#approve-cancel") |> render_click()
    refute has_element?(view, "#approve-dialog")
    assert {:ok, %{decisions: []}} = MergeRequest.get(c.branch)

    view |> element("#approve-button") |> render_click()
    view |> element("#approve-confirm") |> render_click()

    assert {:ok, %{status: :approved, decisions: [%{verdict: :approved, body: ""}], comments: []}} =
             MergeRequest.get(c.branch)

    assert has_element?(view, "#decision-0", "Approved")
    refute has_element?(view, "#decision-0", "The experience is wrong")
  end

  test "rejecting without a word is refused, with the message", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    view |> element("#reject-button") |> render_click()
    view |> form("#reject-form", review: %{body: ""}) |> render_submit()

    assert has_element?(view, "#reject-dialog #dialog-error", "Say what needs work.")
    assert {:ok, %{decisions: []}} = MergeRequest.get(c.branch)
  end

  test "a comment in the round lets Reject go without a note", %{conn: conn} = c do
    {:ok, _} = MergeRequest.comment(c.branch, %{body: "Keep hello."})
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    view |> element("#reject-button") |> render_click()
    view |> form("#reject-form", review: %{body: ""}) |> render_submit()

    assert {:ok, %{status: :in_progress, decisions: [%{verdict: :needs_work, body: ""}]}} =
             MergeRequest.get(c.branch)

    refute has_element?(view, "#reject-dialog")
  end

  test "after a review, the page shows what is new when a commit is addressed",
       %{conn: conn} = c do
    {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "Add a readme.")
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))
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
