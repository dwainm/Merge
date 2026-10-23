defmodule Merge.Git do
  @moduledoc """
  Everything merge knows about a repository comes from running `git` in it.
  `repo` is a bare repository or any worktree of one.
  """

  alias Merge.Diff

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

  @doc "Every path in the tree at `ref`."
  def ls_tree(repo, ref) do
    with {:ok, out} <- git(repo, ["ls-tree", "-r", "--name-only", ref]) do
      {:ok, String.split(out, "\n", trim: true)}
    end
  end

  @doc """
  The contents of `paths` at `ref`, as `%{path => content}`, in one git call
  (`cat-file --batch`). A path that isn't there at `ref` is left out.
  """
  def cat(_repo, _ref, []), do: %{}

  def cat(repo, ref, paths) do
    list = Path.join(System.tmp_dir!(), "merge-cat-#{System.unique_integer([:positive])}")
    File.write!(list, Enum.map_join(paths, "", &"#{ref}:#{&1}\n"))

    try do
      case System.cmd("sh", ["-c", ~s(exec git -C "$1" cat-file --batch < "$2"), "sh", repo, list]) do
        {out, 0} -> batch(out, paths, %{})
        _ -> %{}
      end
    after
      File.rm(list)
    end
  end

  # Each answer is `<sha> <type> <size>\n<content>\n`, or `<spec> missing\n`.
  defp batch(_out, [], acc), do: acc

  defp batch(out, [path | paths], acc) do
    with [header, rest] <- String.split(out, "\n", parts: 2),
         [_sha, _type, size] <- String.split(header, " ") do
      size = String.to_integer(size)
      <<content::binary-size(^size), "\n", rest::binary>> = rest
      batch(rest, paths, Map.put(acc, path, content))
    else
      [_header, rest] -> batch(rest, paths, acc)
      _ -> acc
    end
  end

  @doc "The repo's shared git directory (a worktree's main repo), as an absolute path."
  def common_dir(repo) do
    case git(repo, ["rev-parse", "--git-common-dir"]) do
      {:ok, dir} -> Path.expand(String.trim(dir), repo)
      {:error, _} -> nil
    end
  end

  @doc "The shared git directory of the nearest existing repo at or above `path`, or nil."
  def enclosing_repo(path) do
    path
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.find_value(fn dir -> File.dir?(dir) && common_dir(dir) end)
  end

  @doc "True when `ancestor` is reachable from `ref` (both resolve)."
  def ancestor?(repo, ancestor, ref) do
    match?({:ok, _}, git(repo, ["merge-base", "--is-ancestor", ancestor, ref]))
  end

  @doc "True when the repo has a remote called origin."
  def origin?(repo), do: match?({:ok, _}, git(repo, ["remote", "get-url", "origin"]))

  @doc "Fetches origin, when there is one."
  def fetch(repo) do
    if origin?(repo), do: git(repo, ["fetch", "--quiet", "origin"]), else: {:ok, ""}
  end

  @doc """
  The commit on `target` that brought `head` in: the oldest merge commit on
  target's first-parent line whose second parent reaches `head`, or `head`
  itself (a fast-forward). nil when `head` isn't on `target`.
  """
  def merge_commit(repo, target, head) do
    if ancestor?(repo, head, target) do
      case git(repo, [
             "rev-list",
             "--first-parent",
             "--reverse",
             "--parents",
             "#{head}..#{target}"
           ]) do
        {:ok, out} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split/1)
          |> Enum.find_value(head, fn
            [sha, _first, second | _] -> if ancestor?(repo, head, second), do: sha
            _ -> nil
          end)

        {:error, _} ->
          head
      end
    end
  end

  @doc "One commit's sha, short sha, subject and commit time."
  def commit_info(repo, ref) do
    format = Enum.join(["%H", "%h", "%s", "%cI"], "%x1f")

    with {:ok, out} <- git(repo, ["log", "-1", "--format=#{format}", ref]) do
      [sha, short, subject, date] = out |> String.trim() |> String.split("\x1f", parts: 4)
      {:ok, %{sha: sha, short: short, subject: subject, date: date}}
    end
  end

  @doc """
  Whether `head` merges into `target` without conflicts, by a trial merge that
  touches no worktree (`git merge-tree`): `:clean` or `{:conflicts, files}`.
  """
  def merge_check(repo, target, head) do
    args = [
      "-C",
      repo,
      "merge-tree",
      "--write-tree",
      "--name-only",
      "--no-messages",
      target,
      head
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_, 0} ->
        :clean

      {out, 1} ->
        {:conflicts, out |> String.split("\n", trim: true) |> Enum.drop(1) |> Enum.uniq()}

      {out, _} ->
        {:error, String.trim(out)}
    end
  end

  @doc """
  Pushes local `branch` to origin, or only up to `commit` of it (origin's
  `branch` moves to that commit). Answers git's output either way.
  """
  def push(repo, branch, commit \\ nil)
  def push(repo, branch, nil), do: git(repo, ["push", "origin", branch])

  def push(repo, branch, commit),
    do: git(repo, ["push", "origin", "#{commit}:refs/heads/#{branch}"])

  @doc """
  Moves local `branch` to origin's, fast-forward only: in the worktree that has
  it checked out (a merge --ff-only there), else by fetching into the ref.
  """
  def pull(repo, branch) do
    case checked_out_in(repo, branch) do
      nil -> git(repo, ["fetch", "origin", "#{branch}:#{branch}"])
      worktree -> git(worktree, ["merge", "--ff-only", "origin/#{branch}"])
    end
  end

  defp checked_out_in(repo, branch) do
    Enum.find_value(worktrees(repo), &(&1.branch == branch && &1.path))
  end

  @doc """
  The repo's worktrees that are on disk, the main one first, as `%{path, head,
  branch}`; `branch` is nil for a detached one. A bare repo itself is left out.
  """
  def worktrees(repo) do
    case git(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, out} ->
        out
        |> String.split("\n\n", trim: true)
        |> Enum.map(&worktree/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp worktree(entry) do
    fields =
      Map.new(String.split(entry, "\n", trim: true), fn line ->
        case String.split(line, " ", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, true}
        end
      end)

    unless fields["bare"] || fields["prunable"] do
      %{
        path: fields["worktree"],
        head: fields["HEAD"],
        branch: fields["branch"] && String.replace_prefix(fields["branch"], "refs/heads/", "")
      }
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
