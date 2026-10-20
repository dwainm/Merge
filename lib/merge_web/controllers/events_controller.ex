defmodule MergeWeb.EventsController do
  @moduledoc """
  `GET /api/events?since=<time>`: the event lines after `since` (none without
  it), then every new one as it happens, one per chunk, until the client goes.
  A blank line every 20 seconds tells the client the server is still there.
  """

  use MergeWeb, :controller

  alias Merge.Events

  @heartbeat_ms 20_000

  def index(conn, params) do
    with {:ok, since} <- since(params["since"]) do
      # Subscribed before reading the log, so nothing falls between the two.
      Phoenix.PubSub.subscribe(Merge.PubSub, Events.topic())
      replay = Events.since(since)
      last = replay |> List.last() |> then(&(&1 && Events.time(&1))) || since

      conn =
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      case chunk(conn, Enum.map(replay, &[&1, "\n"])) do
        {:ok, conn} -> stream(conn, last)
        {:error, _} -> conn
      end
    else
      :error ->
        conn |> put_status(400) |> json(%{error: "since is a time like 2026-10-19T14:03:22Z."})
    end
  end

  defp stream(conn, last) do
    receive do
      {:event, line} ->
        # A line the replay already sent is skipped.
        if last == nil or Events.after?(line, last) do
          case chunk(conn, line <> "\n") do
            {:ok, conn} -> stream(conn, Events.time(line))
            {:error, _} -> conn
          end
        else
          stream(conn, last)
        end
    after
      @heartbeat_ms ->
        case chunk(conn, "\n") do
          {:ok, conn} -> stream(conn, last)
          {:error, _} -> conn
        end
    end
  end

  defp since(nil), do: {:ok, nil}
  defp since(""), do: {:ok, nil}

  defp since(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> {:ok, time}
      {:error, _} -> :error
    end
  end
end
