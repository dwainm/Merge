defmodule Merge.ServersTest do
  use ExUnit.Case, async: true

  alias Merge.{GitRepo, Servers}

  setup do
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

    assert [%{name: name, trees: [main, feature]}] = Servers.read([c.repo], listeners)
    assert name == c.name

    assert %{branch: "main", url: "https://main-app.dev.example.com/", ports: [4001, 4002]} =
             main

    assert main.pid == 11 and main.name == Path.basename(c.tree)
    assert %{branch: "feature", url: nil, ports: [], pid: nil, path: path} = feature
    assert path == c.repo
  end

  test "without .dev-url the URL is the localhost port; a tunnel to no server shows none", c do
    assert [%{trees: [%{branch: "main", url: "http://localhost:4001"}, _]}] =
             Servers.read([c.repo], %{c.tree => [%{port: 4001, pid: 1}]})

    File.write!(Path.join(c.tree, ".dev-url"), "https://main-app.dev.example.com/\n")
    assert [%{trees: [%{branch: "main", url: nil}, _]}] = Servers.read([c.repo], %{})
  end

  test "a detached tree is listed only while a server runs in it", c do
    detached = c.repo <> "-detached"
    GitRepo.git!(c.repo, ["worktree", "add", "-q", "--detach", detached])
    on_exit(fn -> File.rm_rf!(detached) end)

    assert [%{trees: trees}] = Servers.read([c.repo], %{})
    refute Enum.any?(trees, &(&1.path == detached))

    assert [%{trees: trees}] = Servers.read([c.repo], %{detached => [%{port: 4003, pid: 3}]})
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

  test "parses ss output into ports by the listening process's directory" do
    pid = System.pid()

    out = """
    LISTEN 0 1024 127.0.0.1:4321 0.0.0.0:* users:(("beam.smp",pid=#{pid},fd=33))
    LISTEN 0 1024 [::]:4321 [::]:* users:(("beam.smp",pid=#{pid},fd=34))
    LISTEN 0 4096 0.0.0.0:139 0.0.0.0:* users:(("smbd",pid=4294967295,fd=5))
    LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
    """

    assert Servers.parse_listeners(out) ==
             %{File.cwd!() => [%{port: 4321, pid: String.to_integer(pid)}]}
  end
end
