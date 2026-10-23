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
    assert has_element?(view, "#push-to-#{one}", "Push to here")
    refute has_element?(view, "#push-to-#{two}")

    view |> element("#push-to-#{one}") |> render_click()
    render_async(view)

    assert has_element?(view, "#push-result", "Pushed 1 commit")
    assert has_element?(view, "#push-result", "main is still 1 commit ahead of GitHub")
    assert %{ahead: [%{short: ^two}], behind: []} = Drift.read(repo)
    refute has_element?(view, "#push-to-#{one}")
  end
end
