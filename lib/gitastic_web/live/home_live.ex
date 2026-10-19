defmodule GitasticWeb.HomeLive do
  @moduledoc "Every open merge request. Empty until an agent opens one."

  use GitasticWeb, :live_view

  alias Gitastic.MergeRequest
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Gitastic.PubSub, MergeRequest.list_topic())

    {:ok, socket |> assign(:page_title, "Merge requests") |> load()}
  end

  @impl true
  def handle_info(:merge_requests_changed, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, :merge_requests, MergeRequest.list())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="mb-4 text-lg font-semibold">Merge requests</h1>

      <div
        :if={@merge_requests == []}
        id="no-merge-requests"
        class="rounded-lg border border-dashed border-zinc-300 bg-white p-6 text-sm text-zinc-500"
      >
        <p>Nothing to review.</p>
        <p class="mt-2">
          An agent opens one with <code class="rounded bg-zinc-100 px-1 font-mono text-xs">gitastic mr open &lt;branch&gt;</code>.
        </p>
      </div>

      <ul
        :if={@merge_requests != []}
        id="merge-requests"
        class="divide-y divide-zinc-200 overflow-hidden rounded-lg border border-zinc-200 bg-white"
      >
        <li :for={mr <- @merge_requests} id={"mr-#{mr.branch}"}>
          <.link
            navigate={GitasticWeb.mr_path(mr.branch)}
            class="block px-4 py-3 transition hover:bg-zinc-50"
          >
            <div class="flex items-start justify-between gap-3">
              <span class="font-medium text-zinc-900">{mr.title}</span>
              <.status status={mr.status} />
            </div>
            <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-zinc-500">
              <span class="font-mono">{mr.branch} → {mr.base}</span>
              <span>{count(mr.commits, "commit")}</span>
              <span>{count(mr.files, "file")}</span>
              <span :if={mr.comments != []}>{count(mr.comments, "comment")}</span>
              <span>by {mr.opened_by}</span>
            </div>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
