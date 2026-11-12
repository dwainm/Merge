defmodule MergeWeb.ShotControllerTest do
  use MergeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Merge.{GitRepo, MergeRequest}

  setup do
    branch = "shot-test-#{System.unique_integer([:positive])}"
    repo = GitRepo.new(branch)
    GitRepo.commit!(repo, %{"README.md" => "# App\n"}, "Add a readme")

    dir = Path.join(System.tmp_dir!(), "merge-shots-#{System.unique_integer([:positive])}")
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
    {:ok, view, _html} = live(conn, MergeWeb.mr_path(c.branch))

    assert has_element?(view, "#mr-body h2", "What")
    # Fetched when it comes near the screen, at an address that names the
    # file's time, so the browser keeps it between visits.
    %{mtime: mtime} = File.stat!(c.named, time: :posix)
    src = MergeWeb.shot_path(c.named, mtime)
    assert has_element?(view, ~s(#mr-body img[loading="lazy"][src="#{src}"]))
    refute has_element?(view, "#mr-body script")
  end

  test "serves a png a body names, and nothing else", %{conn: conn} = c do
    assert conn |> get(MergeWeb.shot_path(c.named)) |> response(200) == "png"

    # Asked each time by its plain address; kept by the browser when the address names its time.
    assert ["no-cache"] =
             conn |> get(MergeWeb.shot_path(c.named)) |> get_resp_header("cache-control")

    kept = conn |> get(MergeWeb.shot_path(c.named, 1)) |> get_resp_header("cache-control")
    assert ["private, max-age=31536000, immutable"] = kept
    assert conn |> get(MergeWeb.shot_path(c.unnamed)) |> response(404)
    assert conn |> get(MergeWeb.shot_path("/etc/passwd")) |> response(404)
    assert conn |> get(MergeWeb.shot_path(c.named <> "/../other.png")) |> response(404)
  end
end
