defmodule Gitastic.Git do
  @moduledoc """
  Everything gitastic knows about a repository comes from running `git` in it.
  `repo` is a bare repository or any worktree of one.
  """

  alias Gitastic.Diff

  @doc "The commit a ref points at, as a full sha."
  def rev_parse(repo, ref) do
    case git(repo, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _} -> {:error, "#{ref} is not a commit in #{repo}"}
    end
  end

  @doc "The base a branch is reviewed against: `origin/main` when the repo has it, else `main`."
  def default_base(repo) do
    case rev_parse(repo, "origin/main") do
      {:ok, _} -> "origin/main"
      {:error, _} -> "main"
    end
  end

  def merge_base(repo, base, branch) do
    with {:ok, sha} <- git(repo, ["merge-base", base, branch]), do: {:ok, String.trim(sha)}
  end

  @doc "True when `commit` is reachable from `branch`."
  def on_branch?(repo, commit, branch) do
    match?({:ok, _}, git(repo, ["merge-base", "--is-ancestor", commit, branch]))
  end

  @doc "The diff of `branch` against `base` from their merge base (`git diff base...branch`)."
  def branch_diff(repo, base, branch), do: diff(repo, ["#{base}...#{branch}"])

  @doc "The diff of one commit against its first parent."
  def commit_diff(repo, sha), do: diff(repo, ["#{sha}^", sha])

  @doc "The diff between two commits."
  def range_diff(repo, from, to), do: diff(repo, [from, to])

  @doc "The commits on `branch` that are not on `base`, newest first."
  def commits(repo, base, branch) do
    format = Enum.join(["%H", "%h", "%an", "%aI", "%s"], "%x1f") <> "%x1e"

    with {:ok, out} <- git(repo, ["log", "--format=#{format}", "#{base}..#{branch}"]) do
      commits =
        out
        |> String.split("\x1e", trim: true)
        |> Enum.map(&String.trim_leading(&1, "\n"))
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          [sha, short, author, date, subject] = String.split(line, "\x1f", parts: 5)
          %{sha: sha, short: short, author: author, date: date, subject: subject}
        end)

      {:ok, commits}
    end
  end

  defp diff(repo, args) do
    with {:ok, out} <- git(repo, ["diff", "--no-color", "--no-ext-diff", "-M"] ++ args) do
      {:ok, Diff.parse(out)}
    end
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo, "-c", "core.quotePath=false" | args],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end
end
