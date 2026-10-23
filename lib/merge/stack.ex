defmodule Merge.Stack do
  @moduledoc """
  What Merge knows about the stacks it reviews, so a merge request reads in the
  order someone who knows the stack would read it.

  A changed file belongs to the nearest `mix.exs` or `package.json` above it at
  the branch tip, which says what stack it is in: a Phoenix (or plain Elixir)
  app, or an Expo (or plain Node) app. Within a stack the file is one kind of
  thing, and the kinds have a reading order: the data model first (migrations,
  then resources and schemas), then the code on it (preparations, changes and
  types, then jobs, then the domain), then what shows it (the router and
  plugs, then LiveViews and components, then assets), then what proves it
  (tests), and config and docs last. A Phoenix file's path doesn't always say what it is (a preparation can
  be a schema, a context a worker), so a module is what it `use`s, read at the
  tip, or at the commit before for a deleted file. A repo with neither marker
  groups by top directory.

  `kinds/4` answers, for each file, `%{root, rank, title}`: the stack's root
  directory, where its kind sits in the reading order, and the group's name.
  """

  alias Merge.Git

  @markers ["mix.exs", "package.json"]

  @doc "The kind of each file: `%{path => %{root, rank, title}}`."
  def kinds(repo, files, tip, before) do
    tree =
      case Git.ls_tree(repo, tip) do
        {:ok, tree} -> tree
        {:error, _} -> Enum.map(files, & &1.path)
      end

    stacks = stacks(repo, tip, tree)
    contents = contents(repo, files, tip, before)

    Map.new(files, fn file ->
      {file.path, kind(stack_of(stacks, file.path), file.path, Map.get(contents, file.path, ""))}
    end)
  end

  # The stacks in the tree: each marker file's directory and what it marks.
  defp stacks(repo, tip, tree) do
    markers =
      Enum.filter(tree, fn path ->
        Path.basename(path) in @markers and
          not (path =~ ~r{(^|/)(node_modules|deps|_build)/})
      end)

    contents = Git.cat(repo, tip, markers)

    for path <- markers, content = contents[path] do
      root = if Path.dirname(path) == ".", do: "", else: Path.dirname(path)

      kind =
        case Path.basename(path) do
          "mix.exs" -> if content =~ ~r/:phoenix\b/, do: :phoenix, else: :elixir
          "package.json" -> if content =~ ~r/"expo"/, do: :expo, else: :node
        end

      %{root: root, kind: kind}
    end
  end

  # The nearest stack above a path: the one with the longest root that holds it.
  defp stack_of(stacks, path) do
    stacks
    |> Enum.filter(fn %{root: root} -> root == "" or String.starts_with?(path, root <> "/") end)
    |> Enum.max_by(&String.length(&1.root), fn -> %{root: "", kind: :generic} end)
  end

  # What a module `use`s decides its kind, so Elixir files are read: at the tip,
  # or, deleted there, at the commit before.
  defp contents(repo, files, tip, before) do
    elixir = Enum.filter(files, &(Path.extname(&1.path) in [".ex", ".exs"]))
    {gone, there} = Enum.split_with(elixir, &(&1.status == :deleted))

    Map.merge(
      Git.cat(repo, tip, Enum.map(there, & &1.path)),
      Git.cat(repo, before, Enum.map(gone, & &1.path))
    )
  end

  defp kind(%{root: root, kind: stack}, path, content) do
    rel = if root == "", do: path, else: String.replace_prefix(path, root <> "/", "")

    {rank, title} =
      case stack do
        :phoenix -> elixir(rel, content)
        :elixir -> elixir(rel, content)
        :expo -> javascript(rel)
        :node -> javascript(rel)
        :generic -> generic(rel)
      end

    %{root: root, rank: rank, title: title}
  end

  # A Phoenix app, in reading order. Paths settle tests, assets and config;
  # for the modules, what they `use` comes first, then where they live.
  defp elixir(rel, content) do
    cond do
      rel =~ ~r{^priv/(repo/migrations|resource_snapshots)/} or
          uses?(content, ~r/Ecto\.Migration\b/) ->
        {10, "Migrations"}

      rel =~ ~r{^test/} ->
        {90, "Tests"}

      uses?(content, ~r/(Ecto\.Schema|Ash\.Resource)\b(?!\.)/) ->
        {20, "Resources and schemas"}

      uses?(content, ~r/Ash\.(Resource\.\w+|Policy\.\w+|Type)\b/) ->
        {30, "Preparations, changes and types"}

      uses?(content, ~r/(Oban\.Worker|Oban\.Pro\.\w+|AshOban)\b/) or rel =~ ~r{(^|/)workers?/} ->
        {40, "Jobs"}

      uses?(
        content,
        ~r/(\w+Web, :(live_view|live_component|html)|Phoenix\.(LiveView|LiveComponent|Component))\b/
      ) or
          rel =~ ~r{^lib/\w+_web/(live|components)/} ->
        {70, "LiveViews and components"}

      rel =~ ~r{^lib/\w+_web/} or uses?(content, ~r/\w+Web, :(controller|router|channel)\b/) ->
        {60, "Router, controllers and plugs"}

      rel =~ ~r{^lib/} ->
        {50, "Domain"}

      rel =~ ~r{^(assets|priv/static)/} ->
        {80, "Assets"}

      rel =~ ~r{^(config/|rel/|docs?/|\.github/|priv/repo/)} or
        rel =~ ~r{^(mix\.exs|mix\.lock|Dockerfile|\.[^/]+)$} or
          rel =~ ~r{\.md$} ->
        {100, "Config and docs"}

      true ->
        {110, "Other"}
    end
  end

  defp uses?(content, pattern) do
    Regex.match?(~r/^\s*use #{Regex.source(pattern)}/m, content)
  end

  # An Expo or Node app: screens, components, the rest of the code, what the
  # platform needs, tests, and config.
  defp javascript(rel) do
    cond do
      rel =~ ~r{^(src/)?app/} ->
        {10, "Screens"}

      rel =~ ~r{(^|/)components/} ->
        {20, "Components"}

      rel =~ ~r{(^|/)(__tests__|tests?)/} or rel =~ ~r{\.(test|spec)\.[jt]sx?$} ->
        {50, "Tests"}

      rel =~ ~r{^(assets|ios|android|public)/} or
          rel =~ ~r{\.(png|jpe?g|gif|svg|webp|ico|ttf|otf|woff2?|mp3|mp4)$} ->
        {40, "Native and assets"}

      rel =~ ~r{\.([jt]sx?|mjs|cjs|css)$} ->
        {30, "Lib and state"}

      true ->
        {60, "Config and docs"}
    end
  end

  # No stack known: the top directory, files at the root last.
  defp generic(rel) do
    case Path.split(rel) do
      [_file] -> {1001, "Top level"}
      [dir | _] -> {1000, dir}
    end
  end
end
