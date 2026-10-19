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
