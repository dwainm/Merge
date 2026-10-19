defmodule Gitastic.MCP.ListMergeRequests do
  @moduledoc "Lists the open merge requests with their state and who is waiting on each."

  use Anubis.Server.Component, type: :tool

  schema do
  end

  @impl true
  def execute(_params, frame) do
    text =
      case Gitastic.MergeRequest.list() do
        [] ->
          "No open merge requests."

        mrs ->
          Enum.map_join(mrs, "\n", fn mr ->
            waiting =
              if mr.waiting == [],
                do: "nobody waiting",
                else: "waiting: " <> Enum.join(mr.waiting, ", ")

            state = GitasticWeb.MergeRequestComponents.status_label(mr.status)
            "#{mr.branch}  #{state}  #{mr.title}  (#{waiting})  #{GitasticWeb.mr_url(mr.branch)}"
          end)
      end

    Gitastic.MCP.reply(text, frame)
  end
end
