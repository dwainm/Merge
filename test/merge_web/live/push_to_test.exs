defmodule MergeWeb.PushToTest do
  # The drift is one for the whole server: this sets its repo.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{Drift, GitRepo}

  setup do
    {repo, _origin} = GitRepo.with_origin()
    was = Application.get_env(:merge, :repo)
    Application.put_env(:merge, :repo, repo)
    Drift.put_current(nil)

    on_exit(fn ->
      Application.put_env(:merge, :repo, was)
      Drift.put_current(nil)
    end)

    one = GitRepo.commit!(repo, %{"ONE.md" => "1\n"}, "One")
    two = GitRepo.commit!(repo, %{"TWO.md" => "2\n"}, "Two")
    %{repo: repo, one: String.slice(one, 0, 7), two: String.slice(two, 0, 7)}
  end

  test "every commit ahead but the tip has Push to here, which leaves the rest ahead",
       %{conn: conn, repo: repo, one: one, two: two} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#drift-ahead")
    assert has_element?(view, "#push-to-#{one}", "Push")
    refute has_element?(view, "#push-to-#{two}")

    view |> element("#push-to-#{one}") |> render_click()
    render_async(view)

    assert has_element?(view, "#push-result", "Pushed 1 commit")
    assert has_element?(view, "#push-result", "main is still 1 commit ahead of GitHub")
    assert %{ahead: [%{short: ^two}], behind: []} = Drift.read(repo)
    refute has_element?(view, "#push-to-#{one}")
  end

  test "each commit links to the diff up to it, which leaves out the ones above", %{
    conn: conn,
    one: one,
    two: two
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#diff-#{one}")
    assert has_element?(view, "#diff-#{two}")

    {:ok, page, _html} =
      view |> element("#diff-#{one}") |> render_click() |> follow_redirect(conn)

    assert has_element?(page, "h1", "main up to #{one} against GitHub")
    assert has_element?(page, "#drift-commit-#{two}.opacity-50")
    refute has_element?(page, "#drift-commit-#{one}.opacity-50")
    assert has_element?(page, "#diff", "ONE.md")
    refute has_element?(page, "#diff", "TWO.md")

    {:ok, whole, _html} = live(conn, ~p"/drift")
    assert has_element?(whole, "#diff", "TWO.md")
    refute has_element?(whole, "#drift-commit-#{two}.opacity-50")
  end
end
