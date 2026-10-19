defmodule Gitastic.MCP.Addressed do
  @moduledoc """
  Tells the reviewer which commit addresses their last decision, with a note.
  The page shows the new diff and the note next to their comments. Then call
  wait_for_review for the next decision.
  """

  use Anubis.Server.Component, type: :tool

  alias Gitastic.MergeRequest

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")

    field(:commit, {:required, :string},
      description: "The commit (sha or ref) on the branch that addresses it"
    )

    field(:note, :string, description: "What you changed, for the reviewer")
    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.addressed(params.branch, params.commit, params[:note], params[:as]) do
      {:ok, a} ->
        Gitastic.MCP.reply(
          "Addressed in #{a.short}. Ready for review again: #{GitasticWeb.mr_url(params.branch)}\nCall wait_for_review for the next decision.",
          frame
        )

      {:error, message} ->
        Gitastic.MCP.error(message, frame)

      :error ->
        Gitastic.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
