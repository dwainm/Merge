defmodule Gitastic.Drift do
  @moduledoc """
  How the repo's local `main` stands against `origin/main` (GitHub): the commits
  each has that the other hasn't. The repo is `gitastic serve --repo`, else the
  first merge request's. `Gitastic.Watcher` fetches and broadcasts it on
  `topic/0` as `{:drift, drift}`, with main's latest CI runs from `gh`;
  `push/0` and `pull/0` close the gap. A push is judged by fetching again
  afterwards, not by git's exit code, and its result is kept until the next.
  """

  alias Gitastic.{Git, MergeRequest}

  def topic, do: "drift"

  @doc "The repo the drift is read in, or nil when there is none yet."
  def repo do
    Application.get_env(:gitastic, :repo) ||
      case MergeRequest.list() do
        [mr | _] -> mr.repo
        [] -> nil
      end
  end

  @doc """
  `%{repo, main, origin, ahead, behind}`, where `ahead` are the commits on main
  not on GitHub and `behind` the other way, newest first. nil without a repo,
  a main or an origin/main.
  """
  def read(repo \\ repo()) do
    with repo when is_binary(repo) <- repo,
         {:ok, main} <- Git.rev_parse(repo, "main"),
         {:ok, origin} <- Git.rev_parse(repo, "origin/main"),
         {:ok, ahead} <- Git.commits(repo, "origin/main", "main"),
         {:ok, behind} <- Git.commits(repo, "main", "origin/main") do
      %{repo: repo, main: main, origin: origin, ahead: ahead, behind: behind}
    else
      _ -> nil
    end
  end

  @doc "The drift the watcher read last (with CI runs), or nil before its first round."
  def current, do: :persistent_term.get({__MODULE__, :current}, nil)

  def put_current(drift), do: :persistent_term.put({__MODULE__, :current}, drift)

  @doc """
  Pushes main to GitHub, fetches, and answers what GitHub has now:
  `%{ok, commits, origin, identical, output, github, at}`. `commits` are the
  ones that were ahead; `ok` when GitHub has every one of them. Kept as the
  last push.
  """
  def push(repo \\ repo()) do
    before = read(repo)
    {_, output} = Git.push(repo, "main")
    Git.fetch(repo)
    now = read(repo)
    ahead = (before && before.ahead) || []
    landed = Enum.filter(ahead, &Git.ancestor?(repo, &1.sha, "origin/main"))

    result = %{
      ok: ahead != [] and length(landed) == length(ahead),
      commits: ahead,
      origin: now && now.origin,
      identical: now != nil and now.main == now.origin,
      output: String.trim(output),
      github: github(repo),
      at: DateTime.utc_now()
    }

    Gitastic.Store.put_named("last_push", result)
    after_git(repo, result)
  end

  @doc "The last push's result, or nil."
  def last_push, do: Gitastic.Store.get_named("last_push")

  @doc "The repo's page on GitHub (`https://github.com/owner/name`), or nil."
  def github(repo) do
    with {url, 0} <- System.cmd("git", ["-C", repo, "remote", "get-url", "origin"]),
         [_, slug] <- Regex.run(~r{github\.com[:/](.+?)(?:\.git)?$}, String.trim(url)) do
      "https://github.com/" <> slug
    else
      _ -> nil
    end
  end

  @doc "The latest run of each workflow on main, from `gh`; [] when it can't tell."
  def ci(repo) do
    with github when is_binary(github) <- github(repo),
         gh when is_binary(gh) <- System.find_executable("gh"),
         slug = String.replace_prefix(github, "https://github.com/", ""),
         {out, 0} <-
           System.cmd(gh, ~w(run list --repo #{slug} --branch main --limit 15
             --json workflowName,status,conclusion,headSha,createdAt,url)),
         {:ok, runs} <- Jason.decode(out) do
      runs |> Enum.uniq_by(& &1["workflowName"]) |> Enum.sort_by(& &1["workflowName"])
    else
      _ -> []
    end
  end

  @doc "Moves main to GitHub's, fast-forward only."
  def pull(repo \\ repo()), do: after_git(repo, Git.pull(repo, "main"))

  @doc "Reads the drift and main's CI, keeps it as current and broadcasts it."
  def refresh(repo \\ repo()) do
    drift = with %{} = d <- read(repo), do: Map.put(d, :ci, ci(repo))
    put_current(drift)
    broadcast(drift)
    drift
  end

  # Every change to main is news for the page and for the merge requests.
  defp after_git(repo, result) do
    refresh(repo)
    Enum.each(MergeRequest.list(), &MergeRequest.check_merged(&1.branch))
    result
  end

  def broadcast(drift), do: Phoenix.PubSub.broadcast(Gitastic.PubSub, topic(), {:drift, drift})
end
