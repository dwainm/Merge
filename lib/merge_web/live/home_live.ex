defmodule MergeWeb.HomeLive do
  @moduledoc """
  Where main stands against GitHub (with Push and Pull), then every open merge
  request, then every tree and its server, then the merged and closed ones.
  """

  use MergeWeb, :live_view

  # How long a successful push's result stays up. A failure stays until the next push.
  @success_ms 10_000

  alias Merge.{Checks, Drift, MergeRequest, Servers}
  import MergeWeb.MergeRequestComponents

  # The queue's tabs; it also follows the merge requests for this page.
  on_mount MergeWeb.QueueHook

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Merge.PubSub, Drift.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, Servers.topic())
      if Process.whereis(Merge.Watcher), do: Merge.Watcher.refresh()
    end

    {:ok,
     socket
     |> assign(page_title: "Merge requests", busy: nil)
     |> show_push(Drift.last_push())
     |> assign(:drift, Drift.current() || Drift.read())
     |> assign(:servers, Servers.current() || Servers.read())
     |> load_checks()
     |> load()}
  end

  @impl true
  def handle_info(:merge_requests_changed, socket), do: {:noreply, load(socket)}

  def handle_info({:drift, drift}, socket),
    do: {:noreply, socket |> assign(drift: drift) |> load_checks()}

  def handle_info({:checks, _sha}, socket), do: {:noreply, socket |> load_checks() |> load()}

  def handle_info({:servers, servers}, socket), do: {:noreply, assign(socket, servers: servers)}

  def handle_info(:hide_push, socket) do
    case socket.assigns.last_push do
      %{ok: true} -> {:noreply, assign(socket, last_push: nil)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  # The Push of one commit ahead: GitHub's main moves to it (Push All on the tip). The
  # confirmation said whether that commit's checks passed.
  def handle_event("push_to", %{"sha" => sha}, socket), do: {:noreply, push(socket, sha)}

  def handle_event("pull", _params, socket) do
    {:noreply, socket |> assign(busy: :pull) |> start_async(:pull, fn -> Drift.pull() end)}
  end

  @impl true
  def handle_async(:push, {:ok, result}, socket) do
    {:noreply, socket |> assign(busy: nil) |> show_push(result)}
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

  # A success shows for a few seconds after it happened, then goes; a failure stays.
  defp show_push(socket, %{ok: true, at: at} = result) do
    left = @success_ms - DateTime.diff(DateTime.utc_now(), at, :millisecond)

    if left > 0 do
      if connected?(socket), do: Process.send_after(self(), :hide_push, left)
      assign(socket, last_push: result)
    else
      assign(socket, last_push: nil)
    end
  end

  defp show_push(socket, result), do: assign(socket, last_push: result)

  defp push(socket, to) do
    socket |> assign(busy: :push) |> start_async(:push, fn -> Drift.push(Drift.repo(), to) end)
  end

  # The checks of main's tip, and of each commit ahead of GitHub (every one was a tip
  # once, unless superseded before its turn): :off without a check command, else
  # Checks.status/1.
  defp load_checks(socket) do
    on? =
      match?(pid when is_pid(pid), Process.whereis(Checks)) and Checks.enabled?()

    status = fn sha -> if on?, do: Checks.status(sha), else: :off end

    case socket.assigns.drift do
      %{main: main, ahead: ahead} ->
        assign(socket,
          checks: status.(main),
          commit_checks: Map.new(ahead, &{&1.sha, status.(&1.sha)})
        )

      _ ->
        assign(socket, checks: :off, commit_checks: %{})
    end
  end

  # The even box: the colour of main's checks, plain when they are off or haven't run.
  defp even_tone(%{ok: true}), do: "border-(--ok-border) bg-(--ok-bg) text-(--ok-text)"
  defp even_tone(%{ok: false}), do: "border-(--bad-border) bg-(--bad-bg) text-(--bad-text)"
  defp even_tone(_), do: "border-(--border) bg-(--surface) text-(--text)"

  defp load(socket) do
    {done, open} = Enum.split_with(MergeRequest.list(), &MergeRequest.done?/1)
    main = socket.assigns[:drift][:main]
    pills = Map.new(done, &{&1.branch, Checks.for_merge_request(&1, main)})
    branches = MapSet.new(open ++ done, & &1.branch)
    assign(socket, open: open, done: done, pills: pills, branches: branches)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} queue={@queue}>
      <.drift
        :if={@drift}
        drift={@drift}
        busy={@busy}
        last_push={@last_push}
        checks={@checks}
        commit_checks={@commit_checks}
      />

      <h1 class="mb-4 text-lg font-semibold">Merge requests</h1>

      <div
        :if={@open == []}
        id="no-merge-requests"
        class="rounded-lg border border-dashed border-(--border) bg-(--surface) p-6 text-sm text-(--text-muted)"
      >
        <p>Nothing to review.</p>
        <p class="mt-2">
          An agent opens one with <code class="rounded bg-(--surface-2) px-1 font-mono text-xs">merge mr open &lt;branch&gt;</code>.
        </p>
      </div>

      <.mr_list
        :if={@open != []}
        id="merge-requests"
        merge_requests={@open}
        queued={MapSet.new(@queue, & &1.branch)}
      />

      <.servers :if={@servers != []} servers={@servers} branches={@branches} />

      <section :if={@done != []} class="mt-8">
        <h2 class="mb-3 text-sm font-semibold text-(--text-muted)">Merged and closed</h2>
        <.mr_list id="done-merge-requests" merge_requests={@done} pills={@pills} />
      </section>
    </Layouts.app>
    """
  end

  attr :drift, :map, required: true
  attr :checks, :any, default: :off
  attr :commit_checks, :map, default: %{}, doc: "the checks of each commit ahead, by sha"
  attr :busy, :atom, default: nil
  attr :last_push, :map, default: nil

  defp drift(assigns) do
    ~H"""
    <section id="drift" class="mb-6 space-y-3">
      <%!-- One line: main is on GitHub, at which commit, and how its checks went. The box
           takes the colour of the checks: green when they passed, red when they failed. --%>
      <div
        :if={@drift.ahead == [] and @drift.behind == []}
        id="drift-even"
        class={["rounded-lg border p-3", even_tone(@checks)]}
      >
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 class="text-sm font-semibold">
            main is on GitHub at
            <span class="font-mono font-normal">{String.slice(@drift.main, 0, 7)}</span>
          </h2>
          <.checks_line
            sha={@drift.main}
            status={@checks}
            id="main-checks"
            show_sha={false}
            class="ml-auto"
          />
        </div>
      </div>

      <.checks_line :if={@drift.behind != []} sha={@drift.main} status={@checks} />

      <div
        :if={@drift.ahead != []}
        id="drift-ahead"
        class="rounded-lg border border-(--warn-border) bg-(--warn-bg) p-3"
      >
        <%!-- One line: how far ahead, the checks of main's tip (the newest commit, just below), the diff. --%>
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 class="text-sm font-semibold text-(--warn-text)">
            main is {count(@drift.ahead, "commit")} ahead of GitHub
          </h2>
          <.checks_line sha={@drift.main} status={@checks} id="main-checks" class="ml-auto" />
        </div>
        <%!-- Each commit has the diff up to it and its own Push: GitHub's main moves to it
             and the ones above stay ahead; the tip's is Push All. The confirmation carries
             that commit's own checks. --%>
        <ol class="mt-1 space-y-1 text-sm">
          <li :for={c <- @drift.ahead} class="flex items-start gap-2">
            <span class="shrink-0 font-mono text-xs leading-5 text-(--warn-text)">{c.short}</span>
            <span class="min-w-0 flex-1 text-(--text)">{c.subject}</span>
            <span class="shrink-0 text-xs leading-5 text-(--text-muted)">{ago(c.date)}</span>
            <.link
              navigate={~p"/drift/#{c.sha}"}
              id={"diff-#{c.short}"}
              title={"The diff up to #{c.short}"}
              class="shrink-0 rounded bg-(--surface) px-2 py-0.5 text-xs font-medium text-(--text-2) ring-1 ring-(--border) hover:bg-(--surface-2)"
            >
              diff
            </.link>
            <.push_to
              commit={c}
              ahead={@drift.ahead}
              checks={@commit_checks[c.sha]}
              busy={@busy}
            />
          </li>
        </ol>
      </div>

      <div
        :if={@drift.behind != []}
        id="drift-behind"
        class="rounded-lg border border-(--info-border) bg-(--info-bg) p-3"
      >
        <h2 class="text-sm font-semibold text-(--info-text)">
          GitHub is {count(@drift.behind, "commit")} ahead of main
        </h2>
        <ol class="mt-2 space-y-1 text-sm">
          <li :for={c <- @drift.behind} class="flex gap-2">
            <span class="shrink-0 font-mono text-xs leading-5 text-(--info-text)">{c.short}</span>
            <span class="min-w-0 flex-1 text-(--text)">{c.subject}</span>
          </li>
        </ol>
        <button
          id="pull-button"
          phx-click="pull"
          data-confirm={"Pull #{count(@drift.behind, "commit")} from GitHub into main (fast-forward only)?"}
          disabled={@busy != nil}
          class="mt-3 w-full rounded-md bg-(--surface) px-4 py-2 text-sm font-medium text-(--info-text) ring-1 ring-(--info-border) hover:bg-(--info-bg) disabled:opacity-50 sm:w-auto"
        >
          {if @busy == :pull, do: "Pulling…", else: "Pull"}
        </button>
      </div>

      <.push_result :if={@last_push} result={@last_push} />

      <ul :if={@drift[:ci] not in [nil, []]} id="ci" class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
        <li :for={run <- @drift.ci}>
          <a href={run["url"]} class="text-(--text-2) hover:underline">
            <span class={run_colour(run)}>●</span>
            {run["workflowName"]}: {run_state(run)}
            <span class="font-mono text-(--text-faint)">{String.slice(run["headSha"], 0, 7)}</span>
          </a>
        </li>
      </ul>
    </section>
    """
  end

  # gh gives a running run's conclusion as "", so its status says more.
  defp run_state(%{"conclusion" => c}) when c not in [nil, ""], do: c
  defp run_state(%{"status" => status}), do: String.replace(status, "_", " ")

  defp run_colour(%{"conclusion" => "success"}), do: "text-(--ok-text)"

  defp run_colour(%{"conclusion" => c}) when c in ["failure", "cancelled", "timed_out"],
    do: "text-(--bad-text)"

  defp run_colour(_), do: "text-(--warn-text)"

  attr :result, :map, required: true

  defp push_result(assigns) do
    ~H"""
    <div
      id="push-result"
      class={[
        "rounded-lg border p-3 text-sm",
        (@result.ok && "border-(--ok-border) bg-(--ok-bg) text-(--ok-text)") ||
          "border-(--bad-border) bg-(--bad-bg) text-(--bad-text)"
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
        {cond do
          @result.identical ->
            "Local main and origin/main are identical."

          @result[:left] not in [nil, []] ->
            "main is still #{count(@result.left, "commit")} ahead of GitHub."

          true ->
            "Local main and origin/main differ again since."
        end}
      </p>
      <p class="mt-1 text-xs opacity-70">{ago(@result.at)}</p>
    </div>
    """
  end

  attr :servers, :list, required: true, doc: "Merge.Servers.read/0"
  attr :branches, :any, required: true, doc: "MapSet of the branches with a merge request"

  # Every tree of each repo, with its server to tap; a branch under review links to it.
  defp servers(assigns) do
    ~H"""
    <section id="servers" class="mt-8">
      <h2 class="mb-3 text-sm font-semibold text-(--text-muted)">Trees and servers</h2>
      <div :for={repo <- @servers} id={"servers-#{repo.name}"} class="mb-4">
        <h3 class="mb-1 flex items-baseline justify-between gap-3 text-xs">
          <span class="font-medium text-(--text-2)">{repo.name}</span>
          <span class="text-(--text-muted)">
            {count(Enum.count(repo.trees, & &1.url), "server")} up in {count(repo.trees, "tree")}
          </span>
        </h3>
        <ul class="divide-y divide-(--border) overflow-hidden rounded-lg border border-(--border) bg-(--surface)">
          <li
            :for={tree <- repo.trees}
            id={"tree-#{repo.name}-#{tree.name}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-2 text-sm"
          >
            <span class="font-mono text-(--text)">
              <.link
                :if={MapSet.member?(@branches, tree.branch)}
                navigate={MergeWeb.mr_path(tree.branch)}
                class="hover:underline"
              >
                {tree.branch}
              </.link>
              <span :if={not MapSet.member?(@branches, tree.branch)}>
                {tree.branch || "(detached)"}
              </span>
            </span>
            <span :if={tree.name != tree.branch} class="text-xs text-(--text-muted)">
              {tree.name}
            </span>
            <.server tree={tree} class="ml-auto" />
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :merge_requests, :list, required: true
  attr :pills, :map, default: %{}
  attr :queued, :any, default: nil, doc: "queued branches; nil hides the queue button"

  defp mr_list(assigns) do
    ~H"""
    <ul
      id={@id}
      class="divide-y divide-(--border) overflow-hidden rounded-lg border border-(--border) bg-(--surface)"
    >
      <li :for={mr <- @merge_requests} id={"mr-#{mr.branch}"} class="flex items-stretch">
        <.link
          navigate={MergeWeb.mr_path(mr.branch)}
          class="block min-w-0 flex-1 px-4 py-3 transition hover:bg-(--surface-2)"
        >
          <div class="flex items-start justify-between gap-3">
            <span class="font-medium text-(--text)">{mr.title}</span>
            <div class="flex shrink-0 items-center gap-1.5">
              <.merge_pill :if={not MergeRequest.done?(mr)} mr={mr} />
              <.checks_pill check={@pills[mr.branch]} link={false} />
              <.status status={mr.status} merged={mr.merged} />
            </div>
          </div>
          <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-(--text-muted)">
            <span class="font-mono">{mr.branch} → {mr.base}</span>
            <span>{count(mr.commits, "commit")}</span>
            <span>{count(mr.files, "file")}</span>
            <span :if={mr.comments != []}>{count(mr.comments, "comment")}</span>
            <span>by {mr.opened_by}</span>
            <span :if={mr.merged} class="font-mono">in {mr.merged.short}</span>
            <span :if={mr.done_at}>{ago(mr.done_at)}</span>
          </div>
        </.link>
        <.queue_button
          :if={@queued && mr.status in [:open, :needs_work]}
          branch={mr.branch}
          queued={MapSet.member?(@queued, mr.branch)}
          class="border-l border-(--border) px-3"
        />
      </li>
    </ul>
    """
  end
end
