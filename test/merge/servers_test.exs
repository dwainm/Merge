defmodule Merge.ServersTest do
  use ExUnit.Case, async: true

  alias Merge.{DevScript, GitRepo, Servers}

  # Every server probed in these tests answers through this stub.
  @req [plug: {Req.Test, __MODULE__}]

  setup do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, "ok"))
    repo = GitRepo.new("feature")
    tree = repo <> "-main"
    GitRepo.git!(repo, ["worktree", "add", "-q", tree, "main"])
    on_exit(fn -> File.rm_rf!(tree) end)
    %{repo: repo, tree: tree, name: Path.basename(repo)}
  end

  test "lists a repo's trees, main first, each with the server listening in it", c do
    File.write!(Path.join(c.tree, ".dev-url"), "https://main-app.dev.example.com/\n")
    # A server in a subdirectory of the tree is the tree's too.
    listeners = %{
      c.tree => [%{port: 4001, pid: 11}],
      Path.join(c.tree, "app") => [%{port: 4002, pid: 12}]
    }

    assert [%{name: name, trees: [main, feature]}] = Servers.read([c.repo], listeners, @req)
    assert name == c.name

    assert %{branch: "main", url: "https://main-app.dev.example.com/", ports: [4001, 4002]} =
             main

    assert main.pid == 11 and main.name == Path.basename(c.tree)
    assert %{branch: "feature", url: nil, ports: [], pid: nil, path: path} = feature
    assert path == c.repo
  end

  test "without .dev-url the URL is the localhost port; a tunnel to no server shows none", c do
    assert [%{trees: [%{branch: "main", url: "http://localhost:4001"}, _]}] =
             Servers.read([c.repo], %{c.tree => [%{port: 4001, pid: 1}]}, @req)

    File.write!(Path.join(c.tree, ".dev-url"), "https://main-app.dev.example.com/\n")
    assert [%{trees: [%{branch: "main", url: nil}, _]}] = Servers.read([c.repo], %{})
  end

  test "a detached tree is listed only while a server runs in it", c do
    detached = c.repo <> "-detached"
    GitRepo.git!(c.repo, ["worktree", "add", "-q", "--detach", detached])
    on_exit(fn -> File.rm_rf!(detached) end)

    assert [%{trees: trees}] = Servers.read([c.repo], %{})
    refute Enum.any?(trees, &(&1.path == detached))

    assert [%{trees: trees}] =
             Servers.read([c.repo], %{detached => [%{port: 4003, pid: 3}]}, @req)

    assert %{branch: nil, url: "http://localhost:4003"} = Enum.find(trees, &(&1.path == detached))
  end

  test "a repo named through any of its trees is listed once; one that is gone not at all", c do
    assert [_] = Servers.read([c.repo, c.tree], %{})
    assert [] = Servers.read([c.repo <> "-nowhere"], %{})
  end

  test "tree_for is the tree the branch is checked out in, else the one it was opened in", c do
    repos = Servers.read([c.repo], %{})

    assert %{branch: "main", path: path} =
             Servers.tree_for(%{branch: "main", repo: c.repo}, repos)

    assert path == c.tree

    assert %{path: path} = Servers.tree_for(%{branch: "gone", repo: c.repo}, repos)
    assert path == c.repo

    assert Servers.tree_for(%{branch: "gone", repo: "/nowhere"}, repos) == nil
  end

  describe "status, from a GET of the tree's URL" do
    setup c, do: %{listeners: %{c.tree => [%{port: 4001, pid: 11}]}}

    defp main_tree(c) do
      [%{trees: trees}] = Servers.read([c.repo], c.listeners, @req)
      Enum.find(trees, &(&1.branch == "main"))
    end

    test "a 2xx or 3xx is up", c do
      assert %{status: :up, reason: nil} = main_tree(c)

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/sign-in") |> Plug.Conn.send_resp(302, "")
      end)

      assert %{status: :up, reason: nil} = main_tree(c)
    end

    test "a 5xx is an error, its page's title the reason", c do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, """
        <html><head><title>CompileError at GET /</title></head><body>…</body></html>
        """)
      end)

      assert %{status: :error, reason: "CompileError"} = main_tree(c)

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 503, "down"))
      assert %{status: :error, reason: "error 503"} = main_tree(c)
    end

    test "a timeout, a refusal or a tunnel's 502 is not answering", c do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      assert %{status: :not_answering, reason: "not answering"} = main_tree(c)

      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert %{status: :not_answering} = main_tree(c)

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 502, "Bad Gateway"))
      assert %{status: :not_answering} = main_tree(c)
    end

    test "no listener is off, and nothing is asked", c do
      Req.Test.stub(__MODULE__, fn _ -> flunk("probed a tree with no server") end)
      assert %{status: :off, reason: nil, url: nil} = main_tree(%{c | listeners: %{}})
      assert Servers.status(c.tree, %{}, @req) == {:off, nil}
    end
  end

  describe "bin/dev" do
    test "a tree without one gets no actions", c do
      assert [%{trees: trees}] = Servers.read([c.repo], %{}, @req)
      assert Enum.all?(trees, &(&1.dev? == false))
      assert DevScript.run(c.tree, "main", "restart") == {:error, :no_script}

      # Not executable is the same as not there.
      script = Path.join([c.tree, "bin", "dev"])
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/bin/sh\necho stopped\n")
      refute DevScript.script?(c.tree)
      assert DevScript.run(c.tree, "main", "off") == {:error, :no_script}

      File.chmod!(script, 0o755)
      assert [%{trees: trees}] = Servers.read([c.repo], %{}, @req)
      assert %{dev?: true} = Enum.find(trees, &(&1.path == c.tree))
    end

    test "Turn off runs bin/dev stop in the tree and says how it went", c do
      script = Path.join([c.tree, "bin", "dev"])
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/bin/sh\necho \"$1 in $(pwd)\"\n")
      File.chmod!(script, 0o755)
      Phoenix.PubSub.subscribe(Merge.PubSub, Servers.topic())

      assert DevScript.run(c.tree, "main", "off") == :ok
      tree = c.tree

      assert_receive {:dev_runs, %{^tree => %{state: :running, action: :off}}}
      assert_receive {:dev_runs, %{^tree => %{state: :ok} = run}}, 5_000
      assert run.message == "Turned off main's server."
      assert run.output == ["$ bin/dev stop", "stop in #{tree}"]
    end
  end

  test "parses ss output into ports by the listening process's directory, without Mix's own" do
    pid = System.pid()

    # 5555 is Mix's build sync (named in a port file, backlog 128); 4322 has a
    # port file left from an old mix run, but a server's backlog.
    out = """
    LISTEN 0 1024 127.0.0.1:4321 0.0.0.0:* users:(("beam.smp",pid=#{pid},fd=33))
    LISTEN 0 1024 [::]:4321 [::]:* users:(("beam.smp",pid=#{pid},fd=34))
    LISTEN 0 128 127.0.0.1:5555 0.0.0.0:* users:(("beam.smp",pid=#{pid},fd=17))
    LISTEN 0 1024 127.0.0.1:4322 0.0.0.0:* users:(("beam.smp",pid=#{pid},fd=35))
    LISTEN 0 4096 0.0.0.0:139 0.0.0.0:* users:(("smbd",pid=4294967295,fd=5))
    LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
    """

    pid = String.to_integer(pid)

    assert Servers.parse_listeners(out, MapSet.new([5555, 4322])) ==
             %{File.cwd!() => [%{port: 4321, pid: pid}, %{port: 4322, pid: pid}]}
  end
end
