defmodule Merge.MCP.WatchEvents do
  @moduledoc """
  Returns the event lines on any merge request or main after `since`, one per
  line: `<time> <event> <branch> <detail>` (opened, comment, approved,
  needs-work, addressed, new-commits, conflicts, merges-cleanly, rewritten,
  branch-gone, merged, on-origin, closed; for main: main-tip, checks-running,
  checks-passed, checks-failed, pushed, push-failed). When there are none yet,
  holds up to 5 minutes for the next. Call it again with the `since` it gives
  you to keep watching; nothing is missed between calls.
  """

  use Anubis.Server.Component, type: :tool

  alias Merge.Events

  schema do
    field(:since, :string,
      description:
        "Return events after this time (as the last answer gave it). Omit for new ones only."
    )
  end

  @impl true
  def execute(params, frame) do
    case since(params[:since]) do
      {:ok, since} ->
        Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())

        lines =
          case Events.since(since) do
            [] -> await(since, Merge.MCP.wait_ms())
            lines -> lines
          end

        Phoenix.PubSub.unsubscribe(Merge.PubSub, Events.topic())
        flush()
        Merge.MCP.reply(text(lines, since), frame)

      :error ->
        Merge.MCP.error("since is a time like 2026-10-19T14:03:22.123456Z.", frame)
    end
  end

  # The first new line, then whatever else comes within a second of it.
  defp await(since, timeout) do
    receive do
      {:event, line} ->
        if Events.after?(line, since), do: [line | more(line)], else: await(since, timeout)
    after
      timeout -> []
    end
  end

  defp more(last) do
    receive do
      {:event, line} ->
        if Events.after?(line, Events.time(last)), do: [line | more(line)], else: more(last)
    after
      1_000 -> []
    end
  end

  defp flush do
    receive do
      {:event, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp text([], since) do
    "No events yet. Call watch_events again with since #{DateTime.to_iso8601(since)}."
  end

  defp text(lines, _since) do
    last = lines |> List.last() |> Events.time() |> DateTime.to_iso8601()
    Enum.join(lines, "\n") <> "\n\nCall watch_events again with since #{last}."
  end

  defp since(nil), do: {:ok, DateTime.utc_now()}

  defp since(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> {:ok, time}
      {:error, _} -> :error
    end
  end
end
