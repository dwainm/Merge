defmodule Merge.MCP.Working do
  @moduledoc """
  Says you are working on the merge request again before anyone rejected it,
  say after a new direction: the page shows it In progress, with your note,
  and the reviewer's queue skips it. When it is ready, call addressed.
  """

  use Anubis.Server.Component, type: :tool

  alias Merge.MergeRequest

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")
    field(:note, :string, description: "What you are doing, shown under the badge")
    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.working(params.branch, params[:note], params[:as]) do
      {:ok, _} ->
        Merge.MCP.reply(
          "In progress: #{MergeWeb.mr_url(params.branch)}\nWhen it is ready again, call addressed with the commit and a note.",
          frame
        )

      {:error, message} ->
        Merge.MCP.error(message, frame)

      :error ->
        Merge.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
