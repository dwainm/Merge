defmodule Merge.ImagePathsTest do
  use ExUnit.Case, async: true

  alias Merge.{GitRepo, ImagePaths}

  # Day of Plenty's, cut down: push has its own filter, only pull_request's paths count.
  @workflow """
  name: Docker

  on:
    push:
      branches: [main]
      paths-ignore:
        - "site/**"
    pull_request:
      paths:
        - "Dockerfile"
        - ".dockerignore"
        - "docker/**"
        - "rel/**"
        - "config/**"
        - 'mix.exs'
        - mix.lock
        - "lib/dop/release.ex"
        - "!config/ignored.exs"

  jobs:
    smoke:
      runs-on: ubuntu-latest
  """

  test "reads pull_request.paths from the workflow, not push's" do
    assert ImagePaths.parse(@workflow) == [
             "Dockerfile",
             ".dockerignore",
             "docker/**",
             "rel/**",
             "config/**",
             "mix.exs",
             "mix.lock",
             "lib/dop/release.ex"
           ]

    assert ImagePaths.parse("on:\n  push:\n    branches: [main]\n") == []
  end

  test "which paths trigger the image check" do
    patterns = ImagePaths.parse(@workflow)

    for path <- ~w(Dockerfile .dockerignore docker/smoke.sh docker/postgres/Dockerfile
                   rel/env.sh.eex config/runtime.exs mix.exs mix.lock lib/dop/release.ex) do
      assert ImagePaths.watched?(patterns, path), path
    end

    for path <- ~w(lib/dop/stock.ex lib/dop/release_notes.ex site/index.html mix.exs.bak
                   sub/Dockerfile dockerfile README.md) do
      refute ImagePaths.watched?(patterns, path), path
    end

    assert ImagePaths.watched?(["lib/*.ex"], "lib/app.ex")
    refute ImagePaths.watched?(["lib/*.ex"], "lib/app/deep.ex")
  end

  test "a commit needs it when it changes a watched path since origin/main" do
    {repo, _origin} = GitRepo.with_origin()
    GitRepo.commit!(repo, %{".github/workflows/docker.yml" => @workflow}, "Workflow")
    GitRepo.git!(repo, ["push", "-q", "origin", "main"])

    code = GitRepo.commit!(repo, %{"lib/dop/stock.ex" => "x\n"}, "Code only")
    refute ImagePaths.needed?(repo, code)

    config = GitRepo.commit!(repo, %{"config/prod.exs" => "x\n"}, "Config")
    assert ImagePaths.needed?(repo, config)

    # Without the workflow, never.
    plain = GitRepo.new()
    GitRepo.git!(plain, ["checkout", "-q", "main"])
    refute ImagePaths.needed?(plain, "HEAD")
  end
end
