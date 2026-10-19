defmodule GitasticWeb.ApiController do
  @moduledoc """
  The JSON API the CLI talks to, on localhost. The branch is always a field,
  not a path segment, since branch names have slashes.
  """

  use GitasticWeb, :controller

  alias Gitastic.{MergeRequest, Report}

  # How long one wait request is held open; the CLI asks again until there is news.
  @wait_ms 50_000

  def index(conn, _params) do
    json(conn, %{merge_requests: Enum.map(MergeRequest.list(), &summary/1)})
  end

  def open(conn, %{"branch" => branch} = params) do
    attrs = %{
      branch: branch,
      repo: params["repo"],
      base: params["base"],
      title: params["title"],
      body: params["body"],
      opened_by: params["as"]
    }

    case MergeRequest.open(attrs) do
      {:ok, mr, how} -> json(conn, %{merge_request: summary(mr), result: how})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def show(conn, %{"branch" => branch}) do
    case MergeRequest.get(branch) do
      {:ok, mr} -> json(conn, %{merge_request: summary(mr)})
      :error -> not_found(conn, branch)
    end
  end

  def wait(conn, %{"branch" => branch} = params) do
    timeout = min(params["timeout_ms"] || @wait_ms, @wait_ms)

    case MergeRequest.wait(branch, params["as"], timeout) do
      {:ok, :timeout} ->
        json(conn, %{status: "waiting"})

      {:ok, outcome} ->
        json(conn, %{
          status: outcome.status,
          kind: outcome.kind,
          decision: outcome.decision,
          comments: outcome.comments,
          text: Report.outcome(outcome, GitasticWeb.mr_url(branch))
        })

      {:error, :not_found} ->
        not_found(conn, branch)
    end
  end

  def addressed(conn, %{"branch" => branch, "commit" => commit} = params) do
    case MergeRequest.addressed(branch, commit, params["note"], params["as"]) do
      {:ok, entry} -> json(conn, %{addressed: entry, url: GitasticWeb.mr_url(branch)})
      {:error, message} -> error(conn, 422, message)
      :error -> not_found(conn, branch)
    end
  end

  def merged(conn, %{"branch" => branch} = params) do
    case MergeRequest.merged(branch, params["commit"]) do
      {:ok, merged} -> json(conn, %{merged: merged, url: GitasticWeb.mr_url(branch)})
      {:error, message} -> error(conn, 422, message)
      :error -> not_found(conn, branch)
    end
  end

  def close(conn, %{"branch" => branch}) do
    case MergeRequest.close(branch) do
      {:ok, status} -> json(conn, %{closed: branch, status: status})
      :error -> not_found(conn, branch)
    end
  end

  defp summary(mr) do
    %{
      branch: mr.branch,
      base: mr.base,
      repo: mr.repo,
      title: mr.title,
      status: mr.status,
      head: mr.head,
      opened_by: mr.opened_by,
      agents: mr.agents,
      waiting: mr.waiting,
      merged: mr.merged,
      merges: merges(mr[:merge_check]),
      conflicts: conflicts(mr[:merge_check]),
      branch_state: branch_state(mr[:branch_state]),
      commits: length(mr.commits),
      files: length(mr.files),
      comments: length(mr.comments),
      url: GitasticWeb.mr_url(mr.branch),
      local_url: GitasticWeb.mr_url(mr.branch, :local)
    }
  end

  defp merges(%{result: :clean}), do: "clean"
  defp merges(%{result: {:conflicts, _}}), do: "conflicts"
  defp merges(_), do: nil

  defp conflicts(%{result: {:conflicts, files}}), do: files
  defp conflicts(_), do: []

  defp branch_state({:rewritten, _}), do: "rewritten"
  defp branch_state(:gone), do: "gone"
  defp branch_state(_), do: "ok"

  defp not_found(conn, branch), do: error(conn, 404, "No open merge request for #{branch}.")

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: to_string(message)})
  end
end
