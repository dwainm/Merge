defmodule Gitastic.GitRepo do
  @moduledoc "Throwaway git repositories for tests."

  import ExUnit.Callbacks, only: [on_exit: 1]

  @env [
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  @doc """
  A new repo with one commit on `main` (lib/app.ex) and a `branch` off it, checked
  out. Removed when the test ends.
  """
  def new(branch \\ "feature") do
    dir = Path.join(System.tmp_dir!(), "gitastic-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(dir, ["init", "-q", "-b", "main"])
    commit!(dir, %{"lib/app.ex" => "defmodule App do\n  def hello, do: :world\nend\n"}, "First")
    git!(dir, ["checkout", "-q", "-b", branch])
    dir
  end

  @doc """
  A bare repo standing in for GitHub and a clone of it with one commit on main,
  pushed. Returns `{clone, origin}`; both are removed when the test ends.
  """
  def with_origin do
    root = Path.join(System.tmp_dir!(), "gitastic-pair-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    clone = Path.join(root, "clone")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(origin, ["init", "-q", "--bare", "-b", "main"])
    {_, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    git!(clone, ["checkout", "-q", "-B", "main"])
    commit!(clone, %{"lib/app.ex" => "defmodule App do\nend\n"}, "First")
    git!(clone, ["push", "-q", "-u", "origin", "main"])
    {clone, origin}
  end

  @doc "Writes the files and commits them on the current branch. Returns the sha."
  def commit!(dir, files, message) do
    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  def git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: @env, stderr_to_stdout: true)
    out
  end
end
