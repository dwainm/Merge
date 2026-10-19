defmodule GitasticWeb.HomeLive do
  @moduledoc """
  Where main stands against GitHub (with Push and Pull), then every open merge
  request, then the merged and closed ones.
  """

  use GitasticWeb, :live_view

  alias Gitastic.{Drift, MergeRequest}
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gitastic.PubSub, MergeRequest.list_topic())
      Phoenix.PubSub.subscribe(Gitastic.PubSub, Drift.topic())
      if Process.whereis(Gitastic.Watcher), do: Gitastic.Watcher.refresh()
    end

    {:ok,
     socket
     |> assign(page_title: "Merge requests", busy: nil, last_push: Drift.last_push())
     |> assign(:drift, Drift.current() || Drift.read())
     |> load()}
  end

  @impl true
  def handle_info(:merge_requests_changed, socket), do: {:noreply, load(socket)}
  def handle_info({:drift, drift}, socket), do: {:noreply, assign(socket, drift: drift)}

  @impl true
  def handle_event("push", _params, socket) do
    {:noreply, socket |> assign(busy: :push) |> start_async(:push, fn -> Drift.push() end)}
  end

  def handle_event("pull", _params, socket) do
    {:noreply, socket |> assign(busy: :pull) |> start_async(:pull, fn -> Drift.pull() end)}
  end

  @impl true
  def handle_async(:push, {:ok, result}, socket) do
    {:noreply, assign(socket, busy: nil, last_push: result)}
  end

  def handle_async(:pull, {:ok, {:ok, _}}, socket) do
    {:noreply, socket |> assign(busy: nil) |> put_flash(:info, "Pulled: main is GitHub's main.")}
  end

  def handle_async(:pull, {:ok, {:error, output}}, socket) do
    {:noreply, socket |> assign(busy: nil) |> put_flash(:error, "Pull failed: " <> output)}
  end

  def handle_async(_name, {:exit, reason}, socket) do
    {:noreply, socket |> assign(busy: nil) |> put_flash(:error, "Failed: #{inspect(reason)}")}
  end

  defp load(socket) do
    {done, open} = Enum.split_with(MergeRequest.list(), &MergeRequest.done?/1)
    assign(socket, open: open, done: done)
  end

  # The confirmation lists what goes out.
  defp push_confirm(ahead) do
    lines = Enum.map_join(ahead, "\n", &"#{&1.short}  #{&1.subject}")
    "Push #{count(ahead, "commit")} to GitHub? This deploys.\n\n" <> lines
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.drift :if={@drift} drift={@drift} busy={@busy} last_push={@last_push} />

      <h1 class="mb-4 text-lg font-semibold">Merge requests</h1>

      <div
        :if={@open == []}
        id="no-merge-requests"
        class="rounded-lg border border-dashed border-zinc-300 bg-white p-6 text-sm text-zinc-500"
      >
        <p>Nothing to review.</p>
        <p class="mt-2">
          An agent opens one with <code class="rounded bg-zinc-100 px-1 font-mono text-xs">gitastic mr open &lt;branch&gt;</code>.
        </p>
      </div>

      <.mr_list :if={@open != []} id="merge-requests" merge_requests={@open} />

      <section :if={@done != []} class="mt-8">
        <h2 class="mb-3 text-sm font-semibold text-zinc-500">Merged and closed</h2>
        <.mr_list id="done-merge-requests" merge_requests={@done} />
      </section>
    </Layouts.app>
    """
  end

  attr :drift, :map, required: true
  attr :busy, :atom, default: nil
  attr :last_push, :map, default: nil

  defp drift(assigns) do
    ~H"""
    <section id="drift" class="mb-6 space-y-3">
      <p
        :if={@drift.ahead == [] and @drift.behind == []}
        id="drift-even"
        class="text-sm text-zinc-500"
      >
        main is on GitHub (<span class="font-mono">{String.slice(@drift.main, 0, 7)}</span>)
      </p>

      <div
        :if={@drift.ahead != []}
        id="drift-ahead"
        class="rounded-lg border border-amber-200 bg-amber-50 p-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h2 class="text-sm font-semibold text-amber-900">
            main is {count(@drift.ahead, "commit")} ahead of GitHub
          </h2>
          <.link navigate={~p"/drift"} class="text-sm text-amber-900 underline">See the diff</.link>
        </div>
        <ol class="mt-2 space-y-1 text-sm">
          <li :for={c <- @drift.ahead} class="flex gap-2">
            <span class="shrink-0 font-mono text-xs leading-5 text-amber-800">{c.short}</span>
            <span class="min-w-0 flex-1 text-zinc-800">{c.subject}</span>
            <span class="shrink-0 text-xs leading-5 text-zinc-500">{ago(c.date)}</span>
          </li>
        </ol>
        <button
          id="push-button"
          phx-click="push"
          data-confirm={push_confirm(@drift.ahead)}
          disabled={@busy != nil}
          class="mt-3 w-full rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-700 disabled:opacity-50 sm:w-auto"
        >
          {if @busy == :push, do: "Pushing…", else: "Push"}
        </button>
      </div>

      <div
        :if={@drift.behind != []}
        id="drift-behind"
        class="rounded-lg border border-sky-200 bg-sky-50 p-3"
      >
        <h2 class="text-sm font-semibold text-sky-900">
          GitHub is {count(@drift.behind, "commit")} ahead of main
        </h2>
        <ol class="mt-2 space-y-1 text-sm">
          <li :for={c <- @drift.behind} class="flex gap-2">
            <span class="shrink-0 font-mono text-xs leading-5 text-sky-800">{c.short}</span>
            <span class="min-w-0 flex-1 text-zinc-800">{c.subject}</span>
          </li>
        </ol>
        <button
          id="pull-button"
          phx-click="pull"
          data-confirm={"Pull #{count(@drift.behind, "commit")} from GitHub into main (fast-forward only)?"}
          disabled={@busy != nil}
          class="mt-3 w-full rounded-md bg-white px-4 py-2 text-sm font-medium text-sky-900 ring-1 ring-sky-300 hover:bg-sky-100 disabled:opacity-50 sm:w-auto"
        >
          {if @busy == :pull, do: "Pulling…", else: "Pull"}
        </button>
      </div>

      <.push_result :if={@last_push} result={@last_push} />

      <ul :if={@drift[:ci] not in [nil, []]} id="ci" class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
        <li :for={run <- @drift.ci}>
          <a href={run["url"]} class="text-zinc-600 hover:underline">
            <span class={run_colour(run)}>●</span>
            {run["workflowName"]}: {run["conclusion"] || run["status"]}
            <span class="font-mono text-zinc-400">{String.slice(run["headSha"], 0, 7)}</span>
          </a>
        </li>
      </ul>
    </section>
    """
  end

  defp run_colour(%{"conclusion" => "success"}), do: "text-emerald-600"

  defp run_colour(%{"conclusion" => c}) when c in ["failure", "cancelled", "timed_out"],
    do: "text-rose-600"

  defp run_colour(_), do: "text-amber-500"

  attr :result, :map, required: true

  defp push_result(assigns) do
    ~H"""
    <div
      id="push-result"
      class={[
        "rounded-lg border p-3 text-sm",
        (@result.ok && "border-emerald-200 bg-emerald-50 text-emerald-900") ||
          "border-rose-200 bg-rose-50 text-rose-900"
      ]}
    >
      <%= if @result.ok do %>
        <p class="font-semibold">
          Pushed {count(@result.commits, "commit")}. GitHub main is now <span class="font-mono">{String.slice(@result.origin, 0, 7)}</span>.
        </p>
      <% else %>
        <p class="font-semibold">The push failed: nothing was pushed.</p>
        <pre class="mt-2 overflow-x-auto whitespace-pre-wrap text-xs">{@result.output}</pre>
      <% end %>
      <ol :if={@result.ok} class="mt-2 space-y-1">
        <li :for={c <- @result.commits} class="flex gap-2">
          <a
            :if={@result.github}
            href={"#{@result.github}/commit/#{c.sha}"}
            class="shrink-0 font-mono text-xs leading-5 underline"
          >
            {c.short}
          </a>
          <span :if={!@result.github} class="shrink-0 font-mono text-xs leading-5">{c.short}</span>
          <span class="min-w-0 flex-1">{c.subject}</span>
        </li>
      </ol>
      <p :if={@result.ok} class="mt-2 text-xs">
        {if @result.identical,
          do: "Local main and origin/main are identical.",
          else: "Local main and origin/main differ again since."}
      </p>
      <p class="mt-1 text-xs opacity-70">{ago(@result.at)}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :merge_requests, :list, required: true

  defp mr_list(assigns) do
    ~H"""
    <ul
      id={@id}
      class="divide-y divide-zinc-200 overflow-hidden rounded-lg border border-zinc-200 bg-white"
    >
      <li :for={mr <- @merge_requests} id={"mr-#{mr.branch}"}>
        <.link
          navigate={GitasticWeb.mr_path(mr.branch)}
          class="block px-4 py-3 transition hover:bg-zinc-50"
        >
          <div class="flex items-start justify-between gap-3">
            <span class="font-medium text-zinc-900">{mr.title}</span>
            <.status status={mr.status} merged={mr.merged} />
          </div>
          <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-zinc-500">
            <span class="font-mono">{mr.branch} → {mr.base}</span>
            <span>{count(mr.commits, "commit")}</span>
            <span>{count(mr.files, "file")}</span>
            <span :if={mr.comments != []}>{count(mr.comments, "comment")}</span>
            <span>by {mr.opened_by}</span>
            <span :if={mr.merged} class="font-mono">in {mr.merged.short}</span>
            <span :if={mr.done_at}>{ago(mr.done_at)}</span>
          </div>
        </.link>
      </li>
    </ul>
    """
  end
end
