defmodule Merge.Highlight do
  @moduledoc """
  Syntax colours for diff lines, by Makeup. Each side of a hunk is lexed as one
  text, so a string or heredoc that spans lines keeps its colour, and the tokens
  are split back into lines.
  """

  @extensions %{
    "heex" => "eex",
    "leex" => "eex",
    "exs" => "ex",
    "mjs" => "js",
    "cjs" => "js",
    "jsx" => "js",
    "ts" => "js",
    "tsx" => "js",
    "htm" => "html",
    "hrl" => "erl"
  }

  @doc "The Makeup lexer for a path, or nil when there is none."
  def lexer_for(path) do
    ext = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    ext = Map.get(@extensions, ext, ext)

    case Makeup.Registry.fetch_lexer_by_extension(ext) do
      {:ok, {lexer, opts}} -> {lexer, opts}
      :error -> nil
    end
  end

  @doc "Each line as HTML with Makeup's token classes (nil without a lexer)."
  def lines(texts, nil), do: Enum.map(texts, fn _ -> nil end)

  def lines(texts, {lexer, opts}) do
    html =
      texts
      |> Enum.join("\n")
      |> lexer.lex(opts)
      |> split_lines()
      |> Enum.map(&Makeup.Formatters.HTML.HTMLFormatter.format_inner_as_binary(&1, []))

    if length(html) == length(texts), do: html, else: lines(texts, nil)
  rescue
    _ -> lines(texts, nil)
  end

  defp split_lines(tokens) do
    {lines, current} =
      Enum.reduce(tokens, {[], []}, fn {type, meta, value}, acc ->
        [first | rest] = value |> to_string() |> String.split("\n")

        Enum.reduce(rest, add(acc, {type, meta, first}), fn part, {lines, current} ->
          {[Enum.reverse(current) | lines], []} |> add({type, meta, part})
        end)
      end)

    Enum.reverse([Enum.reverse(current) | lines])
  end

  defp add(acc, {_, _, ""}), do: acc
  defp add({lines, current}, token), do: {lines, [token | current]}

  @doc """
  The CSS for the token classes, under `.hl`, leaving the background to the
  diff: a high-contrast light style, and a dark one when the system is dark.
  """
  def stylesheet do
    light = Makeup.stylesheet(Makeup.Styles.HTML.StyleMap.vs_style(), "hl")
    dark = Makeup.stylesheet(Makeup.Styles.HTML.StyleMap.one_dark_style(), "hl")

    light <>
      "\n@media (prefers-color-scheme: dark) {\n" <>
      dark <> "\n}\n.hl { background: transparent !important; color: inherit; }\n"
  end
end
