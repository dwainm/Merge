defmodule Merge.Checks.Excerpt do
  @moduledoc """
  The lines of a failed check's log worth showing: those of the first step that
  failed. The check is one command (`mix check` runs hex.audit, format, credo
  and the tests in one go, and an alias carries on past a failing step), so
  there is no exit status per step; each step is found by what it prints when
  it fails:

    * `mix compile --warnings-as-errors`: the warnings, up to "Compilation failed"
    * `mix hex.audit`: "Advisories:" up to "Found packages with security advisories"
    * `mix credo`: from "Checking N source files" to its summary, when that found something
    * `mix test`: from the first failure ("  1) test …") to the result line
    * anything that stops with a Mix error: the `** (…)` line and what follows

  The earliest in the log is the step that failed first. Without any of them,
  the last lines, as before.
  """

  @max 40
  @tail 15

  # {failure line, :back_to start | :on_to end | :after}: the excerpt runs from the
  # last start line before the failure to it, or from the failure to the first end
  # line after it, or from the failure on.
  @steps [
    {~r/^Compilation failed due to warnings/, {:back_to, ~r/^(Compiling \d+ files?|==> )/}},
    {~r/^Found packages with security advisories\s*$/, {:back_to, ~r/^Advisories:/}},
    {~r/mods\/funs, found (?!no issues)/, {:back_to, ~r/^Checking \d+ source files/}},
    {~r/^\s+1\) (test|doctest|property) /,
     {:on_to, ~r/^(Result: |\d+ (doctests?|propert(y|ies)|tests?)\b.*\bfailures?)/}},
    {~r/^\*\* \(/, :after}
  ]

  @doc "The lines of the first step that failed, else the log's last lines."
  def excerpt(log) do
    lines = log |> String.trim_trailing() |> String.split("\n")
    indexed = Enum.with_index(lines)

    found =
      for {failure, how} <- @steps,
          {_, at} <- [Enum.find(indexed, fn {line, _} -> line =~ failure end)],
          do: {at, how}

    case Enum.min_by(found, &elem(&1, 0), fn -> nil end) do
      nil -> lines |> Enum.take(-@tail) |> Enum.join("\n")
      {at, how} -> lines |> span(at, how) |> cap() |> Enum.join("\n")
    end
  end

  defp span(lines, at, {:back_to, start}) do
    from =
      lines
      |> Enum.take(at)
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(at, fn {line, i} -> if line =~ start, do: i end)

    Enum.slice(lines, from..at)
  end

  defp span(lines, at, {:on_to, stop}) do
    after_it = Enum.drop(lines, at + 1)
    n = Enum.find_index(after_it, &(&1 =~ stop)) || length(after_it) - 1
    Enum.slice(lines, at..(at + 1 + n))
  end

  defp span(lines, at, :after), do: Enum.slice(lines, at, @tail)

  # A long step keeps its start and its verdict.
  defp cap(lines) when length(lines) <= @max, do: lines
  defp cap(lines), do: Enum.take(lines, @max - 2) ++ ["…", List.last(lines)]
end
