defmodule Merge.GroupsTest do
  use ExUnit.Case, async: true

  alias Merge.{Git, GitRepo, Groups}

  # A Phoenix app with an Expo app under mobile/, changed on a branch.
  defp phoenix_repo do
    repo = GitRepo.new("stock")

    GitRepo.commit!(
      repo,
      %{
        "mix.exs" => "defp deps, do: [{:phoenix, \"~> 1.8\"}, {:ash, \"~> 3.0\"}]\n",
        "mobile/package.json" => ~s({"dependencies": {"expo": "~54.0.0"}}\n),
        "priv/repo/migrations/20261022_add_stock.exs" =>
          "defmodule Repo.Migrations.AddStock do\n  use Ecto.Migration\nend\n",
        "lib/app/stock/level.ex" => "defmodule App.Stock.Level do\n  use Ash.Resource\nend\n",
        "lib/app/stock/changes/take.ex" =>
          "defmodule App.Stock.Changes.Take do\n  use Ash.Resource.Change\nend\n",
        "lib/app/workers/renew.ex" => "defmodule App.Workers.Renew do\n  use Oban.Worker\nend\n",
        "lib/app/stock.ex" => "defmodule App.Stock do\nend\n",
        "lib/app_web/router.ex" => "defmodule AppWeb.Router do\n  use AppWeb, :router\nend\n",
        "lib/app_web/live/stock_live.ex" =>
          "defmodule AppWeb.StockLive do\n  use AppWeb, :live_view\nend\n",
        "assets/js/barcode.js" => "export default {}\n",
        "assets/vendor/quagga.min.js" => "!function(){}();\n",
        "test/app/stock_test.exs" => "defmodule App.StockTest do\nend\n",
        "README.md" => "# App\n",
        "mobile/src/app/index.tsx" => "export default function Home() {}\n",
        "mobile/src/components/Card.tsx" => "export function Card() {}\n",
        "mobile/src/lib/api.ts" => "export const api = 1\n",
        "mobile/package-lock.json" => "{}\n"
      },
      "Stock"
    )

    repo
  end

  defp diff(repo, branch) do
    {:ok, files} = Git.branch_diff(repo, "main", branch)
    {:ok, tip} = Git.rev_parse(repo, branch)
    {files, tip}
  end

  test "a Phoenix app groups in reading order, and the Expo app under it after" do
    repo = phoenix_repo()
    {files, tip} = diff(repo, "stock")

    groups = Groups.build(repo, files, tip, "main")

    assert Enum.map(groups, &{&1.title, Enum.map(&1.files, fn f -> f.path end)}) == [
             {"Migrations", ["priv/repo/migrations/20261022_add_stock.exs"]},
             {"Resources and schemas", ["lib/app/stock/level.ex"]},
             {"Preparations, changes and types", ["lib/app/stock/changes/take.ex"]},
             {"Jobs", ["lib/app/workers/renew.ex"]},
             {"Domain", ["lib/app/stock.ex"]},
             {"Router, controllers and plugs", ["lib/app_web/router.ex"]},
             {"LiveViews and components", ["lib/app_web/live/stock_live.ex"]},
             {"Assets", ["assets/js/barcode.js", "assets/vendor/quagga.min.js"]},
             {"Tests", ["test/app/stock_test.exs"]},
             {"Config and docs", ["README.md", "mix.exs"]},
             {"mobile: Screens", ["mobile/src/app/index.tsx"]},
             {"mobile: Components", ["mobile/src/components/Card.tsx"]},
             {"mobile: Lib and state", ["mobile/src/lib/api.ts"]},
             {"mobile: Config and docs", ["mobile/package-lock.json", "mobile/package.json"]}
           ]

    assert Enum.map(groups, & &1.id) == Enum.map(0..13, &"group-#{&1}")
    assert groups |> Enum.flat_map(& &1.files) |> Enum.map(& &1.index) == Enum.to_list(0..16)
    assert Enum.all?(groups, &(&1.by == :stack))
  end

  test "the author's groups come first, in their order, and the rest follow by stack" do
    repo = phoenix_repo()
    {files, tip} = diff(repo, "stock")

    text = """
    ## The model
    A level per item per space.
    lib/app/stock/level.ex
    priv/repo/migrations/*

    The page and the scanner it needs
    lib/app_web/live/stock_live.ex
    assets/js/
    lib/app/gone.ex
    """

    groups = Groups.build(repo, files, tip, "main", text)

    assert [
             %{title: "The model", note: "A level per item per space.", by: :author} = model,
             %{title: "The page and the scanner it needs", note: nil, by: :author} = page,
             %{title: "Preparations, changes and types", by: :stack} | _
           ] = groups

    assert Enum.map(model.files, & &1.path) == [
             "lib/app/stock/level.ex",
             "priv/repo/migrations/20261022_add_stock.exs"
           ]

    assert Enum.map(page.files, & &1.path) == [
             "lib/app_web/live/stock_live.ex",
             "assets/js/barcode.js"
           ]

    refute Enum.any?(groups, &(&1.title == "Migrations"))
    assert groups |> Enum.flat_map(& &1.files) |> length() == length(files)
  end

  test "a group whose files are all gone from the diff is dropped, and bare paths get a name" do
    assert [%{title: "Files", patterns: ["lib/a.ex"]}] = Groups.parse("lib/a.ex\n")

    assert Groups.parse("Nothing here\nlib/x.ex\n\n\n") == [
             %{title: "Nothing here", note: nil, patterns: ["lib/x.ex"]}
           ]

    repo = phoenix_repo()
    {files, tip} = diff(repo, "stock")
    groups = Groups.build(repo, files, tip, "main", "Gone\nlib/no/such.ex\n")
    refute Enum.any?(groups, &(&1.title == "Gone"))
  end

  test "a deleted module is read at the commit before, so it still knows what it was" do
    repo = phoenix_repo()
    GitRepo.git!(repo, ["checkout", "-q", "main"])
    GitRepo.git!(repo, ["merge", "-q", "stock"])
    GitRepo.git!(repo, ["checkout", "-q", "-b", "drop"])
    File.rm!(Path.join(repo, "lib/app/stock/level.ex"))
    GitRepo.commit!(repo, %{}, "Drop the level")
    {files, tip} = diff(repo, "drop")

    assert [%{title: "Resources and schemas", files: [%{status: :deleted}]}] =
             Groups.build(repo, files, tip, "main")
  end

  test "a repo with no stack groups by top directory, the root last" do
    repo = GitRepo.new("plain")

    GitRepo.commit!(
      repo,
      %{"README.md" => "# App\n", "lib/b.ex" => "b\n", "docs/a.md" => "a\n"},
      "Plain"
    )

    {files, tip} = diff(repo, "plain")

    assert Enum.map(Groups.build(repo, files, tip, "main"), &{&1.title, length(&1.files)}) ==
             [{"docs", 1}, {"lib", 1}, {"Top level", 1}]
  end

  test "globs, directories and exact paths" do
    assert Groups.matches?("lib/app/stock/*", "lib/app/stock/level.ex")
    refute Groups.matches?("lib/app/stock/*", "lib/app/stock/changes/take.ex")
    assert Groups.matches?("lib/app/**", "lib/app/stock/changes/take.ex")
    assert Groups.matches?("assets/js/", "assets/js/app.js")
    assert Groups.matches?("mix.exs", "mix.exs")
    refute Groups.matches?("mix.exs", "mobile/mix.exs")
  end

  test "quiet files start folded, and the outline drops what a group shares" do
    assert Groups.quiet?(%{path: "mix.lock", binary?: false})
    assert Groups.quiet?(%{path: "assets/vendor/quagga.min.js", binary?: false})
    assert Groups.quiet?(%{path: "priv/resource_snapshots/repo/x.json", binary?: false})
    assert Groups.quiet?(%{path: "icon.png", binary?: true})
    refute Groups.quiet?(%{path: "lib/app.ex", binary?: false})

    files = [%{path: "mobile/src/lib/api.ts"}, %{path: "mobile/src/tools/chat/index.ts"}]
    assert Enum.map(Groups.labels(files), &elem(&1, 0)) == ["lib/api.ts", "tools/chat/index.ts"]
    assert Groups.labels([%{path: "mix.exs"}]) == [{"mix.exs", %{path: "mix.exs"}}]
  end
end
