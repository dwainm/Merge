defmodule Merge.MCP.Reply do
  @moduledoc """
  Answers one of the reviewer's comments, by its id (the #number wait_for_review
  shows). The answer appears under the comment, so say what you will do or did,
  even if it is only "on it".
  """

  use Anubis.Server.Component, type: :tool

  alias Merge.MergeRequest

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")
    field(:id, {:required, :integer}, description: "The comment's id, the #number")
    field(:body, {:required, :string}, description: "Your answer")
    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.reply(params.branch, params.id, params.body, params[:as]) do
      {:ok, _} ->
        Merge.MCP.reply("Replied to ##{params.id}: #{MergeWeb.mr_url(params.branch)}", frame)

      {:error, message} ->
        Merge.MCP.error(message, frame)

      :error ->
        Merge.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
