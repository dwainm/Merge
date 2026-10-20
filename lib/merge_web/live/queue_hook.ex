defmodule MergeWeb.QueueHook do
  @moduledoc """
  Gives a LiveView the review queue's tabs (`@queue`) and the "queue_add" and
  "queue_remove" events. It follows the queue and the merge requests, and wakes
  itself when a decided tab is due to drop out. A tab dropping out never moves
  the page: the tabs are only links.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Merge.{MergeRequest, Queue}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Merge.PubSub, Queue.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, MergeRequest.list_topic())
    end

    socket =
      socket
      |> assign(:queue_timer, nil)
      |> load()
      |> attach_hook(:queue_info, :handle_info, &info/2)
      |> attach_hook(:queue_event, :handle_event, &event/3)

    {:cont, socket}
  end

  defp info(:queue_changed, socket), do: {:halt, load(socket)}
  defp info(:queue_tick, socket), do: {:halt, load(socket)}
  # The page may want this too.
  defp info(:merge_requests_changed, socket), do: {:cont, load(socket)}
  defp info(_msg, socket), do: {:cont, socket}

  defp event("queue_add", %{"branch" => branch}, socket) do
    Queue.add(branch)
    {:halt, socket}
  end

  defp event("queue_remove", %{"branch" => branch}, socket) do
    Queue.remove(branch)
    {:halt, socket}
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  defp load(socket) do
    now = DateTime.utc_now()
    tabs = Queue.tabs(now)
    if timer = socket.assigns[:queue_timer], do: Process.cancel_timer(timer)

    timer =
      case tabs |> Enum.map(& &1.leaving_at) |> Enum.reject(&is_nil/1) do
        [] ->
          nil

        times ->
          due = times |> Enum.min(DateTime) |> DateTime.diff(now, :millisecond)
          if connected?(socket), do: Process.send_after(self(), :queue_tick, max(due, 0) + 50)
      end

    socket |> assign(:queue, tabs) |> assign(:queue_timer, timer)
  end
end
