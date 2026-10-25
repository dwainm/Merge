defmodule Merge.HighlightTest do
  use ExUnit.Case, async: true

  alias Merge.Highlight

  test "a stray backtick is a backtick, not its codepoint" do
    # Outside a string the Elixir lexer gives a backtick as an error token with the
    # codepoint 96 as its value; a hunk that starts inside a moduledoc looks like that.
    [line] = Highlight.lines(["it (`x`)"], Highlight.lexer_for("lib/stock.ex"))
    assert String.replace(line, ~r/<[^>]+>/, "") == "it (`x`)"
    refute line =~ "96"
  end

  test "lines keep their count and a multi-line string keeps its colour" do
    lexer = Highlight.lexer_for("lib/a.ex")
    [one, two] = Highlight.lines(["x = \"a", "b\""], lexer)
    assert one =~ ~s(class="s")
    assert two =~ ~s(class="s")
  end
end
