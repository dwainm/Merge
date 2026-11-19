defmodule Merge.StatusFile do
  @moduledoc """
  `.mr.status` in a merge request's work folder: the stream's own word on
  where it is. The first line is `in progress` or `ready to review`; a second
  line, when there is one, is a short note shown beside it.

      in progress
      Rebuilding the stock page to the new levels

  Merge reads it (`Merge.LiveStatus`), and writes it where a command or the
  reviewer moves the state (`mr open`, `mr addressed`, `mr working`, a
  Reject), so the file and the badge are one thing. A missing file, or one
  that says something else, is "not said": never "ready".

  The file is kept out of git without touching the repo's `.gitignore`: the
  repo's `info/exclude` (one file for the repo and all its worktrees, under
  its git directory) gets a `/.mr.status` line the first time Merge writes one
  (`exclude/1`). And the check for unsaved changes leaves the file out, should
  a repo have it committed anyway.
  """

  @name ".mr.status"

  def name, do: @name

  @doc """
  What the file in `tree` says: `{:ready, note}`, `{:in_progress, note}`,
  `:none` (no file, or it can't be read) or `{:unclear, first_line}`.
  """
  def read(nil), do: :none

  def read(tree) do
    case File.read(Path.join(tree, @name)) do
      {:ok, text} -> parse(text)
      {:error, _} -> :none
    end
  end

  @doc false
  def parse(text) do
    {first, rest} =
      case text
           |> String.split(~r/\r?\n/)
           |> Enum.map(&String.trim/1)
           |> Enum.drop_while(&(&1 == "")) do
        [] -> {"", []}
        [first | rest] -> {first, rest}
      end

    note =
      case Enum.find(rest, &(&1 != "")) do
        nil -> nil
        note -> String.slice(note, 0, 200)
      end

    case first
         |> String.downcase()
         |> String.replace(~r/[\s_-]+/, " ")
         |> String.trim_trailing(".") do
      "" -> :none
      "in progress" -> {:in_progress, note}
      "ready to review" -> {:ready, note}
      "ready for review" -> {:ready, note}
      _ -> {:unclear, String.slice(first, 0, 60)}
    end
  end

  @doc """
  Writes the state into `tree` (`:ready` or `:in_progress`, with an optional
  note), and makes sure git ignores the file. Nothing when `tree` is nil.
  """
  def write(nil, _state, _note), do: :ok

  def write(tree, state, note) do
    line = if state == :ready, do: "ready to review", else: "in progress"

    note =
      case note && note |> String.split("\n") |> hd() |> String.trim() do
        nil -> ""
        "" -> ""
        note -> note <> "\n"
      end

    exclude(tree)

    case File.write(Path.join(tree, @name), line <> "\n" <> note) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds `/.mr.status` to the repo's `info/exclude` (shared by every worktree
  of the repo) unless it is there. Returns :ok whatever happens: a repo whose
  exclude file can't be written still works, its `git status` just lists the
  file as untracked.
  """
  def exclude(tree) do
    with {out, 0} <-
           System.cmd(
             "git",
             ["-C", tree, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"],
             stderr_to_stdout: true
           ),
         path = String.trim(out),
         text = (match?({:ok, _}, File.read(path)) && File.read!(path)) || "",
         false <- String.contains?(text, "/" <> @name) do
      File.mkdir_p(Path.dirname(path))
      sep = if text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"

      File.write(path, sep <> "# Merge's status file, never committed\n/" <> @name <> "\n", [
        :append
      ])
    end

    :ok
  rescue
    _ -> :ok
  end
end
