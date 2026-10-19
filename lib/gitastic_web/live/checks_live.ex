defmodule GitasticWeb.ChecksLive do
  @moduledoc "One commit's checks: where they stand and the whole log, live while they run."

  use GitasticWeb, :live_view

  alias Gitastic.Checks
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(%{"sha" => sha}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Gitastic.PubSub, Checks.topic())
    {:ok, socket |> assign(sha: sha, page_title: "Checks " <> String.slice(sha, 0, 7)) |> load()}
  end

  @impl true
  def handle_info({:checks, _sha}, socket), do: {:noreply, load(socket)}
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  # While a run goes, its log is read again every two seconds.
  defp load(socket) do
    status = Checks.status(socket.assigns.sha)

    if connected?(socket) and match?({:running, _}, status),
      do: Process.send_after(self(), :tick, 2_000)

    assign(socket, status: status, log: Checks.log(socket.assigns.sha))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/"} class="text-sm text-(--link)">← Merge requests</.link>
      <h1 class="mt-2 mb-3 text-lg font-semibold">
        Checks on <span class="font-mono">{String.slice(@sha, 0, 7)}</span>
      </h1>
      <.checks_line sha={@sha} status={@status} />
      <pre
        :if={@log}
        id="checks-log"
        class="mt-4 overflow-x-auto rounded-lg border border-(--border) bg-(--surface) p-3 text-xs leading-5 text-(--text)"
      >{@log}</pre>
    </Layouts.app>
    """
  end
end
