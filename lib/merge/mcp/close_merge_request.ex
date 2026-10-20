defmodule Merge.MCP.CloseMergeRequest do
  @moduledoc """
  Closes a merge request once you are done with it: merged when it was approved,
  closed otherwise. Anyone still waiting is told; it stays on the page, read-only.
  """

  use Anubis.Server.Component, type: :tool

  schema do
    field(:branch, {:required, :string}, description: "The merge request's branch")
  end

  @impl true
  def execute(params, frame) do
    case Merge.MergeRequest.close(params.branch) do
      {:ok, status} -> Merge.MCP.reply("#{params.branch} is #{status}.", frame)
      :error -> Merge.MCP.error("No open merge request for #{params.branch}.", frame)
    end
  end
end
