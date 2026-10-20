defmodule Merge.EventsTest do
  # Sets the events file for the whole app, so not async.
  use MergeWeb.ConnCase, async: false

  alias Merge.{Events, GitRepo, MergeRequest}

  setup do
    file = Path.join(System.tmp_dir!(), "merge-events-#{System.unique_integer([:positive])}")
    Application.put_env(:merge, :events_file, file)

    on_exit(fn ->
      Application.delete_env(:merge, :events_file)
      File.rm(file)
    end)

    Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())
    :ok
  end

  test "a merge request's life is one line per event, kept and broadcast" do
    start = DateTime.utc_now()
    branch = "events-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)

    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Empty it"})

    {:ok, _} =
      MergeRequest.comment(branch, %{body: "Why?\nReally?", path: "lib/app.ex", line: 2})

    GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")
    :ok = MergeRequest.check_branch(branch)

    GitRepo.git!(repo, ["checkout", "-q", "main"])
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\n  def hi, do: 1\nend\n"}, "Main")
    :ok = MergeRequest.check_branch(branch)
    {:ok, _} = MergeRequest.decide(branch, :approved, "")

    events = for line <- Events.since(start), do: line |> String.split(" ", parts: 4) |> tl()

    assert [
             ["opened", ^branch, "Empty it (1 commits) by " <> _],
             ["comment", ^branch, "lib/app.ex:2 reviewer: Why? ⏎ Really?"],
             ["new-commits", ^branch, "1 → " <> _],
             ["conflicts", ^branch, "into main (" <> _],
             ["approved", ^branch, "at " <> _]
           ] = events

    assert_receive {:event, line}
    assert line =~ " opened #{branch} "
  end

  test "since gives the lines after a time, so a reader resumes without repeats" do
    Events.emit("main-tip", "main", "aaa → bbb")
    Events.emit("pushed", "main", "1 commits")
    [first, second] = Events.since(~U[2000-01-01 00:00:00Z])

    assert [^second] = Events.since(Events.time(first))
    assert [] = Events.since(Events.time(second))
    assert second =~ ~r/^\S+ pushed main 1 commits$/
  end

  test "the stream refuses a since it can't read", %{conn: conn} do
    assert %{"error" => _} = conn |> get(~p"/api/events?since=yesterday") |> json_response(400)
  end
end
