defmodule GitasticWeb.ServersPanelTest do
  # The listeners stand-in is one for the whole server.
  use GitasticWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Gitastic.{GitRepo, MergeRequest, Servers}

  setup do
    branch = "servers-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"lib/app.ex" => "defmodule App do\nend\n"}, "Empty the app")
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, title: "Empty it"})
    File.write!(Path.join(repo, ".dev-url"), "https://#{branch}-app.dev.example.com/\n")
    listening(%{repo => [%{port: 4001, pid: 1}]})

    on_exit(fn ->
      Application.delete_env(:gitastic, :listeners)
      MergeRequest.close(branch)
    end)

    %{
      branch: branch,
      repo: repo,
      name: Path.basename(repo),
      host: "#{branch}-app.dev.example.com"
    }
  end

  defp listening(map), do: Application.put_env(:gitastic, :listeners, map)

  # The home page asks the watcher for a round on mount; let it land first.
  defp settled(view) do
    _ = :sys.get_state(Gitastic.Watcher)
    _ = render(view)
    view
  end

  test "the home page lists each tree with its server, which goes as the server does", c do
    {:ok, view, _html} = live(c.conn, ~p"/")
    view = settled(view)
    tree = "#servers-#{c.name} #tree-#{c.name}-#{c.name}"
    assert has_element?(view, "#{tree} a[href='https://#{c.host}/']", c.host)
    assert has_element?(view, "#{tree} a[href='/mr/#{c.branch}']", c.branch)

    listening(%{})
    Servers.refresh()
    assert has_element?(view, tree, "no server")
    refute has_element?(view, "#{tree} a[href='https://#{c.host}/']")
  end

  test "the merge request page says which tree the branch is in, and its server", c do
    {:ok, view, _html} = live(c.conn, ~p"/mr/#{c.branch}")
    assert has_element?(view, "#mr-tree", c.name)
    assert has_element?(view, "#mr-tree a[href='https://#{c.host}/']", c.host)

    listening(%{})
    Servers.refresh()
    assert has_element?(view, "#mr-tree", "no server")
  end
end
