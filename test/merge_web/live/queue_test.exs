defmodule MergeWeb.QueueTest do
  # The queue is one for the whole server.
  use MergeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Merge.{GitRepo, MergeRequest, Queue}

  setup do
    branches =
      for n <- 1..2 do
        branch = "queue-test-#{n}-#{System.unique_integer([:positive])}"
        repo = GitRepo.new(branch)
        GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
        {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Change #{n}"})

        on_exit(fn ->
          Queue.remove(branch)
          MergeRequest.close(branch)
        end)

        branch
      end

    %{branches: branches}
  end

  test "queued from the list, they show as tabs at the top, the first one Next",
       %{conn: conn, branches: [one, two]} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#review-queue")

    view |> element("#queue-button-#{one}") |> render_click()
    view |> element("#queue-button-#{two}") |> render_click()

    assert has_element?(view, "#queue-tab-#{one}", "Next")
    assert has_element?(view, "#queue-tab-#{two}", "Change 2")
    refute has_element?(view, "#queue-tab-#{two}", "Next")
    assert has_element?(view, "#queue-button-#{one}[aria-label=\"Take it off the queue\"]")

    view |> element("#queue-remove-#{one}") |> render_click()
    refute has_element?(view, "#queue-tab-#{one}")
    assert has_element?(view, "#queue-tab-#{two}", "Next")
  end

  test "approved, it fades, the next one is Next, and it drops out without moving the page",
       %{conn: conn, branches: [one, two]} do
    Queue.add(one)
    Queue.add(two)
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(one))

    view |> element("#approve-button") |> render_click()
    view |> element("#approve-confirm") |> render_click()

    assert has_element?(view, "#queue-tab-#{one}.queue-leaving", "Approved")
    assert has_element?(view, "#queue-tab-#{two}", "Next")

    later = DateTime.add(DateTime.utc_now(), Queue.linger_ms() + 1_000, :millisecond)
    assert [%{branch: ^two}] = Enum.filter(Queue.tabs(later), &(&1.branch in [one, two]))

    send(view.pid, :queue_tick)
    assert has_element?(view, "#mr-header")
  end

  test "a merge request page can be queued from its header", %{conn: conn, branches: [one, _]} do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(one))
    view |> element("#queue-button-#{one}") |> render_click()
    assert has_element?(view, "#queue-tab-#{one}", "Next")
    assert has_element?(view, "#queue-button-#{one}[aria-label=\"Take it off the queue\"]")
  end

  test "Next skips one In progress, and its tab says so", %{conn: conn, branches: [one, two]} do
    Queue.add(one)
    Queue.add(two)
    {:ok, _} = MergeRequest.working(one, "New direction", "agent")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#queue-tab-#{one}", "In progress")
    refute has_element?(view, "#queue-tab-#{one}", "Next")
    assert has_element?(view, "#queue-tab-#{two}", "Next")
  end

  test "the merge request page shows In progress with the working note",
       %{conn: conn, branches: [one, _]} do
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(one))
    assert has_element?(view, "#mr-header", "Needs review")
    refute has_element?(view, "#working-note")

    {:ok, _} = MergeRequest.working(one, "Rebuilding to the new decision", "agent")
    assert has_element?(view, "#mr-header", "In progress")
    assert has_element?(view, "#working-note", "Rebuilding to the new decision")
  end
end
