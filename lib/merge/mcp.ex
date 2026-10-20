defmodule Merge.MCP do
  @moduledoc """
  The same actions as the `merge mr` commands, as MCP tools over Streamable
  HTTP at `/mcp`, so a Claude Code session can `claude mcp add` the server.
  """

  use Anubis.Server,
    name: "merge",
    version: "0.1.0",
    capabilities: [:tools]

  # How long one wait_for_review call holds before answering "still waiting".
  # The session runs one request at a time, so this stays well short of forever.
  @wait_ms 300_000

  def wait_ms, do: @wait_ms
  # A request may take the whole wait and a little more.
  def request_timeout, do: @wait_ms + 60_000

  component(Merge.MCP.OpenMergeRequest, name: "open_merge_request")
  component(Merge.MCP.WaitForReview, name: "wait_for_review")
  component(Merge.MCP.Addressed, name: "addressed")
  component(Merge.MCP.Reply, name: "reply")
  component(Merge.MCP.CloseMergeRequest, name: "close_merge_request")
  component(Merge.MCP.ListMergeRequests, name: "list_merge_requests")
  component(Merge.MCP.WatchEvents, name: "watch_events")

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @doc "A tool's text reply."
  def reply(text, frame),
    do: {:reply, Anubis.Server.Response.text(Anubis.Server.Response.tool(), text), frame}

  @doc "A tool's error reply."
  def error(message, frame),
    do:
      {:reply, Anubis.Server.Response.error(Anubis.Server.Response.tool(), to_string(message)),
       frame}
end
