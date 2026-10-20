defmodule Merge.MCP.ListMergeRequests do
  @moduledoc "Lists the open merge requests with their state and who is waiting on each."

  use Anubis.Server.Component, type: :tool

  schema do
  end

  @impl true
  def execute(_params, frame) do
    text =
      case Merge.MergeRequest.list() do
        [] ->
          "No open merge requests."

        mrs ->
          Enum.map_join(mrs, "\n", fn mr ->
            waiting =
              if mr.waiting == [],
                do: "nobody waiting",
                else: "waiting: " <> Enum.join(mr.waiting, ", ")

            state = MergeWeb.MergeRequestComponents.status_label(mr.status)
            "#{mr.branch}  #{state}  #{mr.title}  (#{waiting})  #{MergeWeb.mr_url(mr.branch)}"
          end)
      end

    Merge.MCP.reply(text, frame)
  end
end
