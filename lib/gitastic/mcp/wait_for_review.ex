defmodule Gitastic.MCP.WaitForReview do
  @moduledoc """
  Waits for the reviewer's decision on a merge request and returns it with every
  comment: APPROVED, or NEEDS WORK with what to fix. Returns at once when the
  last decision hasn't been addressed yet. Holds up to 5 minutes; when it answers
  "Still waiting", call it again.
  """

  use Anubis.Server.Component, type: :tool

  alias Gitastic.{MergeRequest, Report}

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")
    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.wait(params.branch, params[:as] || "mcp", Gitastic.MCP.wait_ms()) do
      {:ok, :timeout} ->
        Gitastic.MCP.reply(
          "Still waiting for a review of #{params.branch}. Call wait_for_review again.",
          frame
        )

      {:ok, outcome} ->
        Gitastic.MCP.reply(
          Report.outcome(outcome, GitasticWeb.mr_url(params.branch), :mcp),
          frame
        )

      {:error, :not_found} ->
        Gitastic.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
