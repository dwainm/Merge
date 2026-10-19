defmodule GitasticWeb.HomeLive do
  @moduledoc """
  Where main stands against GitHub (with Push and Pull), then every open merge
  request, then the merged and closed ones.
  """

  use GitasticWeb, :live_view

  # How long a successful push's result stays up. A failure stays until the next push.
  @success_ms 10_000

  alias Gitastic.{Checks, Drift, MergeRequest}
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gitastic.PubSub, MergeRequest.list_topic())
      Phoenix.PubSub.subscribe(Gitastic.PubSub, Drift.topic())
      Phoenix.PubSub.subscribe(Gitastic.PubSub, Checks.topic())
      if Process.whereis(Gitastic.Watcher), do: Gitastic.Watcher.refresh()
    end

    {:ok,
     socket
     |> assign(page_title: "Merge requests", busy: nil)
     |> show_push(Drift.last_push())
     |> assign(:drift, Drift.current() || Drift.read())
     |> load_checks()
     |> load()}
  end

  @impl true
  def handle_info(:merge_requests_changed, socket), do: {:noreply, load(socket)}

  def handle_info({:drift, drift}, socket),
    do: {:noreply, socket |> assign(drift: drift) |> load_checks()}

  def handle_info({:checks, _sha}, socket), do: {:noreply, socket |> load_checks() |> load()}

  def handle_info(:hide_push, socket) do
    case socket.assigns.last_push do
      %{ok: true} -> {:noreply, assign(socket, last_push: nil)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  # Push only what passed the checks; Push anyway is the deliberate way round.
  def handle_event("push", _params, socket) do
    if checks_passed?(socket.assigns.checks) do
      {:noreply, push(socket)}
    else
      {:noreply, put_flash(socket, :error, "main's checks haven't passed. Use Push anyway.")}
    end
  end

  def handle_event("push_anyway", _params, socket), do: {:noreply, push(socket)}

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

  defp push(socket) do
    socket |> assign(busy: :push) |> start_async(:push, fn -> Drift.push() end)
  end

  # The checks of main's tip: :off without a check command, else Checks.status/1.
  defp load_checks(socket) do
    checks =
      with %{main: main} <- socket.assigns.drift,
           pid when is_pid(pid) <- Process.whereis(Checks),
           true <- Checks.enabled?() do
        Checks.status(main)
      else
        _ -> :off
      end

    assign(socket, checks: checks)
  end

  defp checks_passed?(:off), do: true
  defp checks_passed?(%{ok: ok}), do: ok
  defp checks_passed?(_), do: false

  defp load(socket) do
    {done, open} = Enum.split_with(MergeRequest.list(), &MergeRequest.done?/1)
    main = socket.assigns[:drift][:main]
    pills = Map.new(done, &{&1.branch, Checks.for_merge_request(&1, main)})
    assign(socket, open: open, done: done, pills: pills)
  end

  # The confirmation lists what goes out, and what was checked.
  defp push_confirm(ahead, checks) do
    lines = Enum.map_join(ahead, "\n", &"#{&1.short}  #{&1.subject}")

    checked =
      if match?(%{ok: true}, checks),
        do: "\n\nChecks passed on #{String.slice(checks.sha, 0, 7)}.",
        else: ""

    "Push #{count(ahead, "commit")} to GitHub? This deploys.\n\n" <> lines <> checked
  end

  defp push_anyway_confirm(ahead, checks) do
    why =
      case checks do
        %{ok: false} -> "main's checks FAILED."
        {:running, _} -> "main's checks are still running."
        _ -> "main's checks haven't run."
      end

    why <>
      " Push anyway? This deploys code that hasn't passed them.\n\n" <>
      Enum.map_join(ahead, "\n", &"#{&1.short}  #{&1.subject}")
  end

  defp push_label(:push, _checks), do: "Pushing…"
  defp push_label(_busy, %{ok: true}), do: "Push"
  defp push_label(_busy, :off), do: "Push"
  defp push_label(_busy, %{ok: false}), do: "Push (checks failed)"
  defp push_label(_busy, _checks), do: "Push (waiting for checks)"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.drift :if={@drift} drift={@drift} busy={@busy} last_push={@last_push} checks={@checks} />

      <h1 class="mb-4 text-lg font-semibold">Merge requests</h1>

      <div
        :if={@open == []}
        id="no-merge-requests"
        class="rounded-lg border border-dashed border-(--border) bg-(--surface) p-6 text-sm text-(--text-muted)"
      >
        <p>Nothing to review.</p>
        <p class="mt-2">
          An agent opens one with <code class="rounded bg-(--surface-2) px-1 font-mono text-xs">gitastic mr open &lt;branch&gt;</code>.
        </p>
      </div>

      <.mr_list :if={@open != []} id="merge-requests" merge_requests={@open} />

      <section :if={@done != []} class="mt-8">
        <h2 class="mb-3 text-sm font-semibold text-(--text-muted)">Merged and closed</h2>
        <.mr_list id="done-merge-requests" merge_requests={@done} pills={@pills} />
      </section>
    </Layouts.app>
    """
  end

  attr :drift, :map, required: true
  attr :checks, :any, default: :off
  attr :busy, :atom, default: nil
  attr :last_push, :map, default: nil

  defp drift(assigns) do
    ~H"""
    <section id="drift" class="mb-6 space-y-3">
      <p
        :if={@drift.ahead == [] and @drift.behind == []}
        id="drift-even"
        class="text-sm text-(--text-muted)"
      >
        main is on GitHub (<span class="font-mono">{String.slice(@drift.main, 0, 7)}</span>)
      </p>

      <.checks_line :if={@drift.ahead == []} sha={@drift.main} status={@checks} />

      <div
        :if={@drift.ahead != []}
        id="drift-ahead"
        class="rounded-lg border border-(--warn-border) bg-(--warn-bg) p-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h2 class="text-sm font-semibold text-(--warn-text)">
            main is {count(@drift.ahead, "commit")} ahead of GitHub
          </h2>
          <.link navigate={~p"/drift"} class="text-sm text-(--warn-text) underline">See the diff</.link>
        </div>
        <ol class="mt-2 space-y-1 text-sm">
          <li :for={c <- @drift.ahead} class="flex gap-2">
            <span class="shrink-0 font-mono text-xs leading-5 text-(--warn-text)">{c.short}</span>
            <span class="min-w-0 flex-1 text-(--text)">{c.subject}</span>
            <span class="shrink-0 text-xs leading-5 text-(--text-muted)">{ago(c.date)}</span>
          </li>
        </ol>
        <.checks_line sha={@drift.main} status={@checks} id="main-checks" />
        <div class="mt-3 flex flex-col gap-2 sm:flex-row">
          <button
            id="push-button"
            phx-click="push"
            data-confirm={push_confirm(@drift.ahead, @checks)}
            disabled={@busy != nil or not checks_passed?(@checks)}
            class="w-full rounded-md bg-(--btn-bg) px-4 py-2 text-sm font-medium text-(--btn-text) hover:opacity-90 disabled:opacity-50 sm:w-auto"
          >
            {push_label(@busy, @checks)}
          </button>
          <button
            :if={not checks_passed?(@checks)}
            id="push-anyway-button"
            phx-click="push_anyway"
            data-confirm={push_anyway_confirm(@drift.ahead, @checks)}
            disabled={@busy != nil}
            class="w-full rounded-md bg-(--surface) px-4 py-2 text-sm font-medium text-(--bad-text) ring-1 ring-(--bad-border) hover:bg-(--bad-bg) disabled:opacity-50 sm:w-auto"
          >
            Push anyway
          </button>
        </div>
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
  attr :pills, :map, default: %{}

  defp mr_list(assigns) do
    ~H"""
    <ul
      id={@id}
      class="divide-y divide-(--border) overflow-hidden rounded-lg border border-(--border) bg-(--surface)"
    >
      <li :for={mr <- @merge_requests} id={"mr-#{mr.branch}"}>
        <.link
          navigate={GitasticWeb.mr_path(mr.branch)}
          class="block px-4 py-3 transition hover:bg-(--surface-2)"
        >
          <div class="flex items-start justify-between gap-3">
            <span class="font-medium text-(--text)">{mr.title}</span>
            <div class="flex shrink-0 items-center gap-1.5">
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
      </li>
    </ul>
    """
  end
end
