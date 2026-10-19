defmodule GitasticWeb.ShotControllerTest do
  use GitasticWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Gitastic.{GitRepo, MergeRequest}

  setup do
    branch = "shot-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")

    dir = Path.join(System.tmp_dir!(), "gitastic-shots-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    named = Path.join(dir, "home.phone.png")
    unnamed = Path.join(dir, "other.png")
    File.write!(named, "png")
    File.write!(unnamed, "png")

    body = """
    ## What

    The page, on a phone: `#{named}`

    <script>alert(1)</script>
    """

    on_exit(fn -> MergeRequest.close(branch) end)
    {:ok, _, :opened} = MergeRequest.open(%{branch: branch, repo: repo, body: body})
    %{branch: branch, named: named, unnamed: unnamed}
  end

  test "the body is Markdown with its screenshots inline, and no raw HTML", %{conn: conn} = c do
    {:ok, view, _html} = live(conn, GitasticWeb.mr_path(c.branch))

    assert has_element?(view, "#mr-body h2", "What")
    assert has_element?(view, ~s(#mr-body img[src="#{GitasticWeb.shot_path(c.named)}"]))
    refute has_element?(view, "#mr-body script")
  end

  test "serves a png a body names, and nothing else", %{conn: conn} = c do
    assert conn |> get(GitasticWeb.shot_path(c.named)) |> response(200) == "png"
    assert conn |> get(GitasticWeb.shot_path(c.unnamed)) |> response(404)
    assert conn |> get(GitasticWeb.shot_path("/etc/passwd")) |> response(404)
    assert conn |> get(GitasticWeb.shot_path(c.named <> "/../other.png")) |> response(404)
  end
end
