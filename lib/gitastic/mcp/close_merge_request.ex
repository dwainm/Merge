defmodule Gitastic.MCP.CloseMergeRequest do
  @moduledoc "Closes a merge request: anyone still waiting is told, and it leaves the list."

  use Anubis.Server.Component, type: :tool

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")
  end

  @impl true
  def execute(params, frame) do
    case Gitastic.MergeRequest.close(params.branch) do
      :ok -> Gitastic.MCP.reply("Closed #{params.branch}.", frame)
      :error -> Gitastic.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
