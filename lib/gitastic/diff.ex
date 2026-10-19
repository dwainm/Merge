defmodule Gitastic.Diff do
  @moduledoc """
  Parses the output of `git diff` into files, hunks and lines, and gives each
  line its syntax colours.

  A file is `%{path, old_path, status, binary?, additions, deletions, hunks}`; a
  hunk is `%{header, lines}`; a line is `%{type, old, new, text, html}` where
  `type` is `:context`, `:add`, `:del` or `:note` (git's "\\ No newline ...").
  """

  alias Gitastic.Highlight

  def parse(output) do
    output
    |> String.split("\n")
    |> chunk_files()
    |> Enum.map(&parse_file/1)
  end

  defp chunk_files(lines) do
    lines
    |> Enum.chunk_while(
      [],
      fn
        "diff --git " <> _ = line, [] -> {:cont, [line]}
        "diff --git " <> _ = line, acc -> {:cont, Enum.reverse(acc), [line]}
        _line, [] -> {:cont, []}
        line, acc -> {:cont, [line | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp parse_file(["diff --git " <> paths | rest]) do
    {header, body} = Enum.split_while(rest, &(not String.starts_with?(&1, "@@")))
    {old_path, new_path} = paths_from(header, paths)

    status =
      cond do
        Enum.any?(header, &String.starts_with?(&1, "new file mode")) -> :added
        Enum.any?(header, &String.starts_with?(&1, "deleted file mode")) -> :deleted
        old_path != new_path -> :renamed
        true -> :modified
      end

    hunks = parse_hunks(body, Highlight.lexer_for(new_path))

    lines = Enum.flat_map(hunks, & &1.lines)

    %{
      path: new_path,
      old_path: old_path,
      status: status,
      binary?: Enum.any?(header, &String.starts_with?(&1, "Binary files")),
      additions: Enum.count(lines, &(&1.type == :add)),
      deletions: Enum.count(lines, &(&1.type == :del)),
      hunks: hunks
    }
  end

  # The ---/+++ lines name the paths unambiguously; renames and binary files
  # may not have them, so fall back to rename lines and then the diff --git line.
  defp paths_from(header, paths) do
    old = find(header, "--- a/") || find(header, "rename from ")
    new = find(header, "+++ b/") || find(header, "rename to ")

    case {old, new} do
      {nil, nil} ->
        [a, b] = split_git_paths(paths)
        {a, b}

      {nil, new} ->
        {new, new}

      {old, nil} ->
        {old, old}

      both ->
        both
    end
  end

  defp find(header, prefix) do
    Enum.find_value(header, fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  defp split_git_paths("a/" <> rest) do
    case String.split(rest, " b/", parts: 2) do
      [a, b] -> [a, b]
      [a] -> [a, a]
    end
  end

  defp split_git_paths(other), do: [other, other]

  defp parse_hunks(body, lexer) do
    body
    |> Enum.chunk_while(
      nil,
      fn
        "@@" <> _ = line, nil -> {:cont, {line, []}}
        "@@" <> _ = line, acc -> {:cont, acc, {line, []}}
        _line, nil -> {:cont, nil}
        line, {header, lines} -> {:cont, {header, [line | lines]}}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.map(fn {header, lines} -> parse_hunk(header, Enum.reverse(lines), lexer) end)
  end

  defp parse_hunk(header, raw, lexer) do
    [old_start, new_start] =
      case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, header) do
        [_, o, n] -> [String.to_integer(o), String.to_integer(n)]
        _ -> [1, 1]
      end

    {lines, _} =
      Enum.flat_map_reduce(raw, {old_start, new_start}, fn
        " " <> text, {o, n} -> {[line(:context, o, n, text)], {o + 1, n + 1}}
        "+" <> text, {o, n} -> {[line(:add, nil, n, text)], {o, n + 1}}
        "-" <> text, {o, n} -> {[line(:del, o, nil, text)], {o + 1, n}}
        "\\" <> text, acc -> {[line(:note, nil, nil, text)], acc}
        # The empty string after the last newline of the output.
        "", acc -> {[], acc}
        text, {o, n} -> {[line(:context, o, n, text)], {o + 1, n + 1}}
      end)

    %{header: header, lines: highlight(lines, lexer)}
  end

  defp line(type, old, new, text), do: %{type: type, old: old, new: new, text: text, html: nil}

  # The new side (context and additions) and the old side (context and
  # deletions) are each coloured as one text; deletions take the old side's.
  defp highlight(lines, lexer) do
    new_side = Enum.filter(lines, &(&1.type in [:context, :add]))
    old_side = Enum.filter(lines, &(&1.type in [:context, :del]))
    new_html = Highlight.lines(Enum.map(new_side, & &1.text), lexer)
    old_html = Highlight.lines(Enum.map(old_side, & &1.text), lexer)

    dels =
      old_side
      |> Enum.zip(old_html)
      |> Enum.filter(fn {line, _} -> line.type == :del end)
      |> Enum.map(&elem(&1, 1))

    {lines, {[], []}} =
      Enum.map_reduce(lines, {new_html, dels}, fn
        %{type: :del} = line, {news, [html | dels]} -> {%{line | html: html}, {news, dels}}
        %{type: :note} = line, acc -> {line, acc}
        line, {[html | news], dels} -> {%{line | html: html}, {news, dels}}
      end)

    lines
  end
end
