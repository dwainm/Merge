defmodule Merge.Drift do
  @moduledoc """
  How the repo's local `main` stands against `origin/main` (GitHub): the commits
  each has that the other hasn't. The repo is `merge serve --repo`, else the
  first merge request's. `Merge.Watcher` fetches and broadcasts it on
  `topic/0` as `{:drift, drift}`, with main's latest CI runs from `gh`;
  `push/0` and `pull/0` close the gap, `push/2` with a commit closes part of
  it. A push is judged by fetching again afterwards, not by git's exit code. A failure stays on the home page until
  the next push; a success shows for a few seconds.
  """

  alias Merge.{Events, Git, MergeRequest}

  def topic, do: "drift"

  @doc "The repo the drift is read in, or nil when there is none yet."
  def repo do
    Application.get_env(:merge, :repo) ||
      case MergeRequest.list() do
        [mr | _] -> MergeRequest.git_repo(mr)
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
  Pushes main to GitHub, or only up to `to` (a sha among the commits ahead:
  GitHub's main moves to it, the rest stays ahead), fetches, and answers what
  GitHub has now: `%{ok, commits, to, origin, identical, left, output, github,
  at}`. `commits` are the ones that were to go; `ok` when GitHub has every one
  of them; `left` the commits still ahead afterwards. Kept as the last push.
  """
  def push(repo \\ repo(), to \\ "main") do
    before = read(repo)
    ahead = (before && before.ahead) || []
    commits = if to == "main", do: ahead, else: Enum.drop_while(ahead, &(&1.sha != to))

    {_, output} =
      cond do
        commits == [] and to != "main" -> {:error, "#{Events.short(to)} is not ahead of GitHub."}
        to == "main" -> Git.push(repo, "main")
        true -> Git.push(repo, "main", to)
      end

    Git.fetch(repo)
    now = read(repo)
    landed = Enum.filter(commits, &Git.ancestor?(repo, &1.sha, "origin/main"))

    result = %{
      ok: commits != [] and length(landed) == length(commits),
      commits: commits,
      to: to,
      origin: now && now.origin,
      identical: now != nil and now.main == now.origin,
      left: (now && now.ahead) || [],
      output: String.trim(output),
      github: github(repo),
      at: DateTime.utc_now()
    }

    Merge.Store.put_named("last_push", result)

    if result.ok,
      do:
        Events.emit(
          "pushed",
          "main",
          "#{length(commits)} commits, origin at #{Events.short(result.origin)}"
        ),
      else: Events.emit("push-failed", "main", result.output)

    after_git(repo, result)
  end

  # A new tip of main since the last read (none on the first read after a start).
  defp emit_tip(%{main: old}, %{main: new} = drift) when old != new do
    subject =
      case Git.commit_info(drift.repo, new) do
        {:ok, %{subject: s}} -> " " <> s
        _ -> ""
      end

    Events.emit("main-tip", "main", "#{Events.short(old)} → #{Events.short(new)}#{subject}")
  end

  defp emit_tip(_old, _new), do: :ok

  @doc "The last push's result, or nil."
  def last_push, do: Merge.Store.get_named("last_push")

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
    emit_tip(current(), drift)
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

  def broadcast(drift), do: Phoenix.PubSub.broadcast(Merge.PubSub, topic(), {:drift, drift})
end
