defmodule Merge.MCP.WaitForReview do
  @moduledoc """
  Waits for news on a merge request and returns it: each new COMMENT (file, line
  and text), or the decision, APPROVED or NEEDS WORK, with the comments since you
  last heard. Returns at once when there is news you haven't heard. Call it again
  after each answer to keep listening. Holds up to 5 minutes; when it answers
  "Still waiting", call it again.
  """

  use Anubis.Server.Component, type: :tool

  alias Merge.{MergeRequest, Report}

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")

    field(:as, {:required, :string},
      description: "Your name: each name hears each comment and decision once"
    )
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.wait(params.branch, params.as, Merge.MCP.wait_ms()) do
      {:ok, :timeout} ->
        Merge.MCP.reply(
          "Still waiting for a review of #{params.branch}. Call wait_for_review again.",
          frame
        )

      {:ok, outcome} ->
        Merge.MCP.reply(
          Report.outcome(outcome, MergeWeb.mr_url(params.branch), :mcp),
          frame
        )

      {:error, :not_found} ->
        Merge.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
