defmodule Merge.MCP.Addressed do
  @moduledoc """
  Tells the reviewer which commit addresses their last decision, with a note.
  The page shows the new diff and the note next to their comments. Then call
  wait_for_review for the next decision.
  """

  use Anubis.Server.Component, type: :tool

  alias Merge.MergeRequest

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")

    field(:commit, {:required, :string},
      description: "The commit (sha or ref) on the branch that addresses it"
    )

    field(:note, :string, description: "What you changed, for the reviewer")

    field(:groups, :string,
      description:
        "Replaces how the files group on the page, in reading order: a heading line, the paths under it (a file, a glob like lib/app/stock/*, or a directory like assets/js/), a blank line between groups. Lines after the heading that aren't paths are the group's note. Files not named fall into Merge's own groups for the stack."
    )

    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.addressed(
           params.branch,
           params.commit,
           params[:note],
           params[:as],
           params[:groups]
         ) do
      {:ok, a} ->
        Merge.MCP.reply(
          "Addressed in #{a.short}. Ready for review again: #{MergeWeb.mr_url(params.branch)}\nCall wait_for_review for the next decision.",
          frame
        )

      {:error, message} ->
        Merge.MCP.error(message, frame)

      :error ->
        Merge.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
