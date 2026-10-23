defmodule Merge.Groups do
  @moduledoc """
  The files of a diff in groups, in reading order.

  The author can say how the files group, as text: a heading per group, then
  the paths under it, blank line between groups. A heading is any line that
  isn't a path; further such lines are the group's note. A path is a file in
  the diff, a glob (`lib/dop/stock/*`, `**` for any depth), or a directory
  (`assets/js/`). Groups keep the order written, and the files keep the order
  of their lines. A path that isn't in the diff (any more) is skipped, and a
  group left with no files is dropped.

      The model: a level per item per space
      lib/dop/stock/level.ex
      lib/dop/stock/amount.ex

      The pages, and the barcode scanner they share
      lib/dop_web/live/stock_tab.ex
      assets/js/barcode_scan.js

  Files the author didn't place follow in the groups `Merge.Stack` knows for
  them, so a file added by a later push is never hidden.

  A group is `%{id, title, note, files, additions, deletions, by}` (`by` is
  `:author` or `:stack`); each file carries its `index` in the whole list, the
  DOM id it has on the page.
  """

  alias Merge.Stack

  @doc "The groups of `files`, placed by the author's `text` first, then by the stack."
  def build(repo, files, tip, before, text \\ nil) do
    {named, rest} = place(parse(text), files)

    by_stack =
      if rest == [] do
        []
      else
        kinds = Stack.kinds(repo, rest, tip, before)

        rest
        |> Enum.group_by(&kinds[&1.path])
        |> Enum.sort_by(fn {kind, _} -> {kind.root != "", kind.root, kind.rank, kind.title} end)
        |> Enum.map(fn {kind, files} -> group(stack_title(kind), nil, files, :stack) end)
      end

    (named ++ by_stack)
    |> Enum.with_index()
    |> Enum.map_reduce(0, fn {group, i}, n ->
      files =
        group.files |> Enum.with_index(n) |> Enum.map(fn {f, j} -> Map.put(f, :index, j) end)

      {%{group | id: "group-#{i}", files: files}, n + length(files)}
    end)
    |> elem(0)
  end

  defp stack_title(%{root: "", title: title}), do: title
  defp stack_title(%{root: root, title: title}), do: "#{root}: #{title}"

  defp group(title, note, files, by) do
    %{
      id: nil,
      title: title,
      note: note,
      files: files,
      additions: Enum.sum_by(files, & &1.additions),
      deletions: Enum.sum_by(files, & &1.deletions),
      by: by
    }
  end

  @doc "The author's text as `[%{title, note, patterns}]`."
  def parse(nil), do: []

  def parse(text) do
    text
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(fn chunk ->
      chunk |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn lines ->
      {patterns, words} = Enum.split_with(lines, &path_like?/1)

      {title, note} =
        case words do
          [] -> {"Files", nil}
          [title | rest] -> {String.trim_leading(title, "#") |> String.trim(), note(rest)}
        end

      %{title: title, note: note, patterns: patterns}
    end)
  end

  defp note([]), do: nil
  defp note(lines), do: Enum.join(lines, " ")

  # No spaces, and a slash, a dot or a star somewhere: a path or a glob.
  defp path_like?(line), do: Regex.match?(~r{^\S*[/.*]\S*$}, line)

  # Each named group takes the files its patterns name, in that order, out of
  # the files still unplaced. The groups left empty go.
  defp place(groups, files) do
    {placed, rest} =
      Enum.map_reduce(groups, files, fn %{patterns: patterns} = g, rest ->
        taken =
          patterns
          |> Enum.flat_map(fn pattern -> Enum.filter(rest, &matches?(pattern, &1.path)) end)
          |> Enum.uniq_by(& &1.path)

        {group(g.title, g.note, taken, :author), rest -- taken}
      end)

    {Enum.reject(placed, &(&1.files == [])), rest}
  end

  @doc "True when `path` is the file, is under the directory, or fits the glob."
  def matches?(pattern, path) do
    cond do
      String.contains?(pattern, "*") -> Regex.match?(glob(pattern), path)
      String.ends_with?(pattern, "/") -> String.starts_with?(path, pattern)
      true -> pattern == path
    end
  end

  defp glob(pattern) do
    source =
      pattern
      |> String.split(~r/\*\*|\*/, include_captures: true)
      |> Enum.map_join(fn
        "**" -> ".*"
        "*" -> "[^/]*"
        text -> Regex.escape(text)
      end)

    ~r/^#{source}$/
  end

  @doc """
  True for a file nobody reads line by line: a lockfile, vendored or minified
  code, built assets, a snapshot, a binary. Such a file starts folded.
  """
  def quiet?(%{binary?: true}), do: true

  def quiet?(%{path: path}) do
    path =~
      ~r{(^|/)(vendor|node_modules|_build|deps)/|\.min\.(js|css)$|(^|/)(mix\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|Podfile\.lock)$|(^|/)priv/(static|resource_snapshots)/|\.snap$}
  end

  @doc """
  Each file of a group with the name it goes by in the outline: its path less
  the directory the whole group shares, as `[{label, file}]`.
  """
  def labels([file]), do: [{file.path, file}]

  def labels(files) do
    prefix =
      files
      |> Enum.map(&(&1.path |> Path.split() |> Enum.drop(-1)))
      |> Enum.reduce(fn dirs, common ->
        common
        |> Enum.zip(dirs)
        |> Enum.take_while(fn {a, b} -> a == b end)
        |> Enum.map(&elem(&1, 0))
      end)
      |> length()

    Enum.map(files, fn file ->
      {file.path |> Path.split() |> Enum.drop(prefix) |> Path.join(), file}
    end)
  end
end
