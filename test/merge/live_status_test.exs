defmodule Merge.LiveStatusTest do
  # The readings are one map on the board, shared by every merge request: one
  # test at a time. Each round reads only its own test's branch (`only:`).
  use ExUnit.Case, async: false

  alias Merge.{Events, GitRepo, LiveStatus, MergeRequest, StatusFile}

  @req [plug: {Req.Test, __MODULE__}]

  setup do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "ok"))
    branch = "live-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    on_exit(fn -> MergeRequest.close(branch) end)

    {:ok, _mr, :opened} =
      MergeRequest.open(%{branch: branch, repo: repo, title: "Live", opened_by: "agent-a"})

    %{branch: branch, repo: repo}
  end

  defp look(c, listeners \\ %{}) do
    LiveStatus.run(only: [c.branch], listeners: listeners, req: @req)
    verdict(c)
  end

  defp verdict(c) do
    {:ok, mr} = MergeRequest.get(c.branch)
    LiveStatus.verdict(mr, LiveStatus.get(c.branch))
  end

  defp status_file(c, text), do: File.write!(Path.join(c.repo, ".mr.status"), text)

  describe "the rule: ready only when the file says so, nothing is unsaved, and the site answers" do
    test "opening writes ready to review, and with nothing in the way it is Ready to review", c do
      assert {:ready, nil} = StatusFile.read(c.repo)
      assert %{ready?: true, label: "Ready to review", reasons: []} = look(c)
    end

    test "no status file is not said, not ready", c do
      File.rm!(Path.join(c.repo, ".mr.status"))

      assert %{ready?: false, label: "Not said", reasons: [{:not_said, "No status file"}]} =
               look(c)
    end

    test "a file that says something else is not said either", c do
      status_file(c, "done!\n")

      assert %{ready?: false, reasons: [{:not_said, "Status file says \"done!\""}]} = look(c)
    end

    test "in progress, with its note, puts the merge request In progress", c do
      status_file(c, "in progress\nRebuilding the stock page\n")

      assert %{ready?: false, label: "In progress", reasons: [{:in_progress, text}]} = look(c)
      assert text == "In progress: Rebuilding the stock page"
      assert {:ok, %{status: :in_progress} = mr} = MergeRequest.get(c.branch)
      assert %{note: "Rebuilding the stock page", by: "agent-a"} = MergeRequest.working_note(mr)
    end

    test "changes to tracked files that aren't committed: Being changed, whatever the file says",
         c do
      File.write!(Path.join(c.repo, "lib/app.ex"), "defmodule App do\n  # wip\nend\n")

      assert %{
               ready?: false,
               label: "Being changed",
               reasons: [{:changes, "1 file not committed"}]
             } =
               look(c)

      # Staged counts too.
      GitRepo.git!(c.repo, ["add", "lib/app.ex"])
      assert %{reasons: [{:changes, "1 file not committed"}]} = look(c)
    end

    test "untracked files and the status file itself don't count as changes", c do
      File.write!(Path.join(c.repo, "notes.txt"), "scratch\n")
      assert %{ready?: true} = look(c)
      # And git keeps the status file out of its status: info/exclude has it.
      refute GitRepo.git!(c.repo, ["status", "--porcelain"]) =~ ".mr.status"
    end

    test "a test site that isn't running is down", c do
      File.write!(Path.join(c.repo, ".dev-url"), "https://live.dev.example.com/\n")

      assert %{ready?: false, label: "Test site down", reasons: [{:site_down, text}]} = look(c)
      assert text == "Test site is down (no server running)"
    end

    test "a test site that answers 5xx is down; 2xx and 3xx are up", c do
      File.write!(Path.join(c.repo, ".dev-url"), "https://live.dev.example.com/\n")
      listeners = %{c.repo => [%{port: 4100, pid: 1}]}

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "<title>CompileError at GET /</title>")
      end)

      assert %{reasons: [{:site_down, "Test site is down (CompileError)"}]} = look(c, listeners)

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 502, "bad gateway"))
      assert %{reasons: [{:site_down, "Test site is down (not answering)"}]} = look(c, listeners)

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/sign-in") |> Plug.Conn.send_resp(302, "")
      end)

      assert %{ready?: true, label: "Ready to review"} = look(c, listeners)
    end

    test "a tree with no test site has no such line", c do
      assert %{ready?: true} = look(c)
      assert %{site: %{state: :none}} = LiveStatus.get(c.branch)
    end

    test "everything in the way is said, in order", c do
      status_file(c, "in progress\n")
      File.write!(Path.join(c.repo, "lib/app.ex"), "changed\n")
      File.write!(Path.join(c.repo, ".dev-url"), "https://live.dev.example.com/\n")

      assert %{label: "In progress", reasons: reasons} = v = look(c)
      assert Enum.map(reasons, &elem(&1, 0)) == [:in_progress, :changes, :site_down]

      assert LiveStatus.line(v) ==
               "In progress; 1 file not committed; Test site is down (no server running)"
    end

    test "a branch checked out nowhere reads as the commands said", c do
      GitRepo.git!(c.repo, ["checkout", "-q", "main"])
      assert %{ready?: true, label: "Needs review"} = look(c)

      {:ok, _} = MergeRequest.working(c.branch, "On it", "agent-a")
      assert %{label: "In progress", reasons: [{:in_progress, "In progress: On it"}]} = verdict(c)
    end
  end

  describe "the file and the commands are one source" do
    test "Reject writes in progress; the file turning ready hands it back", c do
      look(c)
      {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "Rename it")
      assert {:in_progress, "Sent back: Rename it"} = StatusFile.read(c.repo)
      assert %{label: "In progress"} = look(c)

      status_file(c, "ready to review\nRenamed\n")
      assert %{ready?: true} = look(c)
      assert {:ok, %{status: :open}} = MergeRequest.get(c.branch)
    end

    test "working and addressed write the file", c do
      {:ok, _} = MergeRequest.working(c.branch, "New direction", "agent-a")
      assert {:in_progress, "New direction"} = StatusFile.read(c.repo)

      sha = GitRepo.commit!(c.repo, %{"lib/b.ex" => "b\n"}, "B")
      {:ok, _} = MergeRequest.addressed(c.branch, sha, "Done", "agent-a")
      assert {:ready, "Done"} = StatusFile.read(c.repo)
    end

    test "an old ready to review never undoes a Reject", c do
      look(c)
      # A Reject whose file write didn't land: the file says ready, as at the last round.
      {:ok, _} = MergeRequest.decide(c.branch, :needs_work, "No")
      status_file(c, "ready to review\n")

      assert %{label: "In progress", reasons: [{:in_progress, _}]} = look(c)
      assert {:ok, %{status: :in_progress}} = MergeRequest.get(c.branch)

      # Written again by the stream, after the Reject: that is its word.
      status_file(c, "in progress\n")
      look(c)
      status_file(c, "ready to review\nDone\n")
      assert %{ready?: true} = look(c)
      assert {:ok, %{status: :open}} = MergeRequest.get(c.branch)
    end
  end

  describe "events" do
    setup c do
      Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())
      c
    end

    defp event(c, name) do
      branch = c.branch
      assert_receive {:event, line}, 2_000

      case String.split(line, " ", parts: 4) do
        [_time, ^name, ^branch | rest] -> rest
        _ -> event(c, name)
      end
    end

    test "the first reading says nothing; a change says what is in the way, then ready", c do
      look(c)
      refute_receive {:event, _}, 100

      File.write!(Path.join(c.repo, "lib/app.ex"), "changed\n")
      look(c)
      assert ["1 file not committed"] = event(c, "not-ready")

      # Another file changed: the same thing in the way, nothing new to say.
      File.write!(Path.join(c.repo, "lib/new.ex"), "x\n")
      GitRepo.git!(c.repo, ["add", "lib/new.ex"])
      look(c)
      refute_receive {:event, _}, 100

      GitRepo.git!(c.repo, ["add", "-A"])
      GitRepo.git!(c.repo, ["commit", "-q", "-m", "Save"])
      look(c)
      assert [] = event(c, "ready-to-review")
    end
  end

  test "since you looked: the commits that came after the reviewer's last look", c do
    MergeRequest.looked(c.branch)
    # A cast: the process has taken it once it answers anything.
    [{pid, _}] = Registry.lookup(Merge.Registry, c.branch)
    _ = :sys.get_state(pid)
    {:ok, mr} = MergeRequest.get(c.branch)
    assert %{head: head} = mr.looked
    assert head == mr.head
    assert MergeRequest.since_looked(mr) == []

    GitRepo.commit!(c.repo, %{"lib/b.ex" => "b\n"}, "Add b")
    GitRepo.commit!(c.repo, %{"lib/c.ex" => "c\n"}, "Add c")
    :ok = MergeRequest.check_branch(c.branch)
    {:ok, mr} = MergeRequest.get(c.branch)
    assert ["Add c", "Add b"] = Enum.map(MergeRequest.since_looked(mr), & &1.subject)
  end

  describe "the status file" do
    test "reads the two values, a note, and nothing else as said" do
      assert {:ready, nil} = StatusFile.parse("ready to review\n")
      assert {:ready, "Fixed"} = StatusFile.parse("Ready to review\nFixed\n")
      assert {:in_progress, "x"} = StatusFile.parse("\n in-progress \n\n x \n")
      assert :none = StatusFile.parse("")
      assert {:unclear, "ready"} = StatusFile.parse("ready\n")
      assert :none = StatusFile.read("/nonexistent")
      assert :none = StatusFile.read(nil)
    end

    test "excludes itself once, in the repo's info/exclude", c do
      StatusFile.exclude(c.repo)
      StatusFile.exclude(c.repo)
      text = File.read!(Path.join(c.repo, ".git/info/exclude"))
      assert length(String.split(text, "/.mr.status")) == 2
    end
  end
end
