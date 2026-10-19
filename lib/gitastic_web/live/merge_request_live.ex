defmodule GitasticWeb.MergeRequestLive do
  @moduledoc """
  One merge request: the diff of the branch against its base, file by file, the
  commits on the right (one commit's diff alone when clicked), comments on any
  line and in general, and Approve or Reject at the bottom. It follows the merge
  request's topic, so it updates when a commit is addressed or a decision lands.
  """

  use GitasticWeb, :live_view

  alias Gitastic.{Checks, Drift, Git, MergeRequest}
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(%{"branch" => parts}, _session, socket) do
    branch = Enum.join(parts, "/")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gitastic.PubSub, MergeRequest.topic(branch))
      Phoenix.PubSub.subscribe(Gitastic.PubSub, Checks.topic())
    end

    mr =
      case MergeRequest.get(branch) do
        {:ok, mr} -> mr
        :error -> nil
      end

    {:ok,
     socket
     |> assign(branch: branch, mr: mr, picked: nil, page_title: (mr && mr.title) || branch)
     |> assign(line_form: blank_form(:line), comment_form: blank_form(:comment))
     |> assign(decision_form: blank_form(:decision))}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{mr: nil}} = socket) do
    _ = params
    {:noreply, assign(socket, view: :branch, files: [], diff_error: nil)}
  end

  def handle_params(params, _uri, socket) do
    view =
      cond do
        sha = params["commit"] -> {:commit, sha}
        params["since"] == "review" -> :since
        true -> :branch
      end

    {:noreply, socket |> assign(view: view, picked: nil) |> load_files()}
  end

  @impl true
  def handle_info({:checks, _sha}, socket), do: {:noreply, main_checks(socket)}

  def handle_info({:merge_request, mr}, socket) do
    {:noreply, socket |> assign(mr: mr, page_title: mr.title) |> load_files()}
  end

  @impl true
  def handle_event("pick", %{"path" => path, "side" => side, "line" => line}, socket) do
    {:noreply,
     assign(socket, picked: {path, side, String.to_integer(line)}, line_form: blank_form(:line))}
  end

  def handle_event("unpick", _params, socket), do: {:noreply, assign(socket, picked: nil)}

  def handle_event("line_comment", %{"line" => %{"body" => body}}, socket) do
    {path, side, line} = socket.assigns.picked

    attrs = %{body: body, path: path, side: side, line: line, commit: view_commit(socket)}

    case MergeRequest.comment(socket.assigns.branch, attrs) do
      {:ok, _} -> {:noreply, assign(socket, picked: nil)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      :error -> {:noreply, gone(socket)}
    end
  end

  def handle_event("comment", %{"comment" => %{"body" => body}}, socket) do
    case MergeRequest.comment(socket.assigns.branch, %{body: body}) do
      {:ok, _} -> {:noreply, assign(socket, comment_form: blank_form(:comment))}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      :error -> {:noreply, gone(socket)}
    end
  end

  def handle_event("decide", %{"decision" => %{"body" => body}} = params, socket) do
    verdict = if params["verdict"] == "approve", do: :approved, else: :needs_work

    case MergeRequest.decide(socket.assigns.branch, verdict, body) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(decision_form: blank_form(:decision))
         |> put_flash(:info, if(verdict == :approved, do: "Approved.", else: "Sent back."))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      :error ->
        {:noreply, gone(socket)}
    end
  end

  defp gone(socket) do
    socket |> put_flash(:error, "This merge request is gone.") |> push_navigate(to: ~p"/")
  end

  defp blank_form(name), do: to_form(%{"body" => ""}, as: name)

  defp view_commit(%{assigns: %{view: {:commit, sha}}}), do: sha
  defp view_commit(_socket), do: nil

  defp last_decision(mr), do: List.last(mr.decisions)

  # The files for the current view. The branch diff is the process's cached one.
  defp load_files(%{assigns: %{mr: mr, view: view}} = socket) do
    result =
      case view do
        :branch ->
          {:ok, mr.files}

        {:commit, sha} ->
          if Enum.any?(mr.commits, &(&1.sha == sha)),
            do: Git.commit_diff(MergeRequest.git_repo(mr), sha),
            else: {:error, "That commit is not on #{mr.branch}."}

        :since ->
          case last_decision(mr) do
            nil -> {:ok, mr.files}
            d -> Git.range_diff(MergeRequest.git_repo(mr), d.head, mr.head)
          end
      end

    case result do
      {:ok, files} -> assign(socket, files: files, diff_error: nil)
      {:error, message} -> assign(socket, files: [], diff_error: message)
    end
    |> assign_derived()
  end

  defp assign_derived(%{assigns: %{mr: mr}} = socket) do
    commit = view_commit(socket)

    line_comments =
      mr.comments
      |> Enum.filter(&(&1.path && &1.line && &1.commit == commit))
      |> Enum.group_by(&{&1.path, &1.side, &1.line})

    new_since =
      case last_decision(mr) do
        nil ->
          nil

        d ->
          mr.commits
          |> Enum.take_while(&(&1.sha != d.head))
          |> then(fn new -> if length(new) == length(mr.commits), do: [], else: new end)
          |> MapSet.new(& &1.sha)
      end

    socket
    |> main_checks()
    |> assign(
      line_comments: line_comments,
      new_since: new_since,
      selected: commit && Enum.find(mr.commits, &(&1.sha == commit))
    )
  end

  # Once merged, where main's checks stand, so the stream knows its merge is safe.
  defp main_checks(%{assigns: %{mr: %{merged: %{}}}} = socket) do
    with %{main: main} <- Drift.current(),
         pid when is_pid(pid) <- Process.whereis(Checks),
         true <- Checks.enabled?() do
      assign(socket, main_checks: {main, Checks.status(main)})
    else
      _ -> assign(socket, main_checks: nil)
    end
  end

  defp main_checks(socket), do: assign(socket, main_checks: nil)

  # The conversation, in order: comments, decisions and addressed commits.
  defp timeline(mr) do
    Enum.map(mr.comments, &{:comment, &1}) ++
      Enum.map(mr.decisions, &{:decision, &1}) ++
      Enum.map(mr.addressed, &{:addressed, &1})
  end

  defp sorted_timeline(mr), do: Enum.sort_by(timeline(mr), &elem(&1, 1).at, DateTime)

  defp addressed_for(mr, comment), do: Enum.filter(mr.addressed, &(&1.round == comment.round))

  @impl true
  def render(%{mr: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="not-found" class="rounded-lg border border-(--border) bg-(--surface) p-6 text-sm">
        <p>No open merge request for <span class="font-mono">{@branch}</span>.</p>
        <.link navigate={~p"/"} class="mt-3 inline-block text-(--link)">All merge requests</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header id="mr-header" class="mb-4">
        <div class="flex items-start justify-between gap-3">
          <h1 class="text-lg font-semibold leading-snug">{@mr.title}</h1>
          <.status status={@mr.status} merged={@mr.merged} />
        </div>
        <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-(--text-muted)">
          <span class="font-mono">{@mr.branch} → {@mr.base}</span>
          <span>opened by {@mr.opened_by} {ago(@mr.opened_at)}</span>
          <span id="agents">
            told: {Enum.join(@mr.agents, ", ")}
            <span :if={@mr.waiting != []} class="text-(--ok-text)">
              (waiting now: {Enum.join(@mr.waiting, ", ")})
            </span>
          </span>
        </div>
        <div :if={@mr.body != ""} id="mr-body" class="markdown mt-3 max-w-3xl text-sm text-(--text-2)">
          {Phoenix.HTML.raw(Gitastic.Body.to_html(@mr.body))}
        </div>
      </header>

      <div
        :if={MergeRequest.done?(@mr)}
        id="done-banner"
        class={[
          "mb-4 rounded-lg px-3 py-2 text-sm",
          @mr.status == :merged && "bg-(--merged-bg) text-(--merged-text)",
          @mr.status == :closed && "bg-(--surface-2) text-(--text-2)"
        ]}
      >
        <%= if @mr.merged do %>
          <p class="font-medium">{merged_line(@mr.merged)}</p>
          <p class="mt-0.5 text-xs opacity-80">
            {ago(@mr.merged.date)} · {if @mr.merged.pushed,
              do: "On origin in #{@mr.merged.short}",
              else: "Not pushed to origin yet"} · the diff is as it was then.
          </p>
          <div :if={@main_checks} class="mt-2">
            <.checks_line
              lead="main at"
              sha={elem(@main_checks, 0)}
              status={elem(@main_checks, 1)}
              id="main-checks"
            />
          </div>
        <% else %>
          {status_label(@mr.status)} {ago(@mr.done_at)}. Kept to look back at: the diff is as it was then.
        <% end %>
      </div>

      <div
        :if={@new_since && MapSet.size(@new_since) > 0 && @view != :since}
        id="since-review"
        class="mb-4 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-(--warn-border) bg-(--warn-bg) px-3 py-2 text-sm text-(--warn-text)"
      >
        <span>
          {count(MapSet.size(@new_since), "new commit")} since your last review.
        </span>
        <.link
          patch={GitasticWeb.mr_path(@mr.branch) <> "?since=review"}
          class="font-medium underline"
        >
          Show what changed
        </.link>
      </div>

      <div class="flex flex-col gap-4 lg:grid lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start lg:gap-5">
        <aside
          id="commits-panel"
          class="overflow-hidden rounded-lg border border-(--border) bg-(--surface) lg:sticky lg:top-4 lg:order-last"
        >
          <div class="flex items-center justify-between border-b border-(--border) bg-(--surface-2) px-3 py-2 text-xs font-medium text-(--text-2)">
            <span>{count(@mr.commits, "commit")}, newest first</span>
          </div>
          <div class="max-h-56 overflow-y-auto lg:max-h-[calc(100vh-8rem)]">
            <.commit_list
              commits={@mr.commits}
              branch={@mr.branch}
              selected={@selected && @selected.sha}
              new_since={@new_since}
            />
          </div>
        </aside>

        <section id="diff" class="min-w-0 space-y-3">
          <nav class="flex flex-wrap items-center gap-2 text-sm">
            <.link
              patch={GitasticWeb.mr_path(@mr.branch)}
              class={[
                "rounded-md px-2.5 py-1",
                (@view == :branch && "bg-(--btn-bg) text-(--btn-text)") ||
                  "bg-(--surface) text-(--text-2) ring-1 ring-(--border)"
              ]}
            >
              All changes
            </.link>
            <.link
              :if={@mr.decisions != []}
              patch={GitasticWeb.mr_path(@mr.branch) <> "?since=review"}
              class={[
                "rounded-md px-2.5 py-1",
                (@view == :since && "bg-(--btn-bg) text-(--btn-text)") ||
                  "bg-(--surface) text-(--text-2) ring-1 ring-(--border)"
              ]}
            >
              Since your review
            </.link>
            <span
              :if={@selected}
              id="selected-commit"
              class="flex min-w-0 items-center gap-2 rounded-md bg-(--info-bg) px-2.5 py-1 text-(--info-text)"
            >
              <span class="font-mono text-xs">{@selected.short}</span>
              <span class="truncate">{@selected.subject}</span>
            </span>
            <span class="ml-auto text-xs text-(--text-muted)">
              {count(@files, "file")} ·
              <span class="text-(--ok-text)">+{Enum.sum_by(@files, & &1.additions)}</span>
              <span class="text-(--bad-text)">−{Enum.sum_by(@files, & &1.deletions)}</span>
            </span>
          </nav>

          <p :if={@diff_error} class="rounded-lg bg-(--bad-bg) px-3 py-2 text-sm text-(--bad-text)">
            {@diff_error}
          </p>
          <p
            :if={!@diff_error && @files == []}
            id="no-changes"
            class="rounded-lg border border-(--border) bg-(--surface) px-3 py-4 text-sm text-(--text-muted)"
          >
            No changes.
          </p>

          <.diff_file
            :for={{file, i} <- Enum.with_index(@files)}
            file={file}
            index={i}
            line_comments={@line_comments}
            picked={@picked}
            commentable={not MergeRequest.done?(@mr)}
          >
            <:comment :let={comment}>
              <.comment comment={comment} addressed={addressed_for(@mr, comment)} />
            </:comment>
            <:comment_form>
              <.form
                for={@line_form}
                id="line-comment-form"
                phx-submit="line_comment"
                class="space-y-2"
              >
                <textarea
                  name={@line_form[:body].name}
                  id="line-comment-body"
                  rows="3"
                  phx-mounted={JS.focus()}
                  placeholder="Comment on this line"
                  class="w-full rounded-md border border-(--border) bg-(--surface) px-2 py-1.5 text-base focus:border-(--link) sm:text-sm focus:outline-none"
                >{@line_form[:body].value}</textarea>
                <div class="flex gap-2">
                  <button class="rounded-md bg-(--btn-bg) px-3 py-1.5 text-sm text-(--btn-text) hover:opacity-90">
                    Comment
                  </button>
                  <button
                    type="button"
                    phx-click="unpick"
                    class="rounded-md px-3 py-1.5 text-sm text-(--text-2) hover:bg-(--surface-2)"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </:comment_form>
          </.diff_file>
        </section>
      </div>

      <section id="conversation" class="mt-6 max-w-3xl space-y-3">
        <h2 class="text-sm font-semibold text-(--text-2)">Conversation</h2>
        <%= for item <- sorted_timeline(@mr) do %>
          <%= case item do %>
            <% {:comment, c} -> %>
              <div
                id={"comment-#{c.id}"}
                class="rounded-lg border border-(--border) bg-(--surface) px-3 py-2"
              >
                <.comment comment={c} addressed={[]} show_location />
              </div>
            <% {:decision, d} -> %>
              <div
                id={"decision-#{d.round}"}
                class={[
                  "rounded-lg px-3 py-2 text-sm",
                  d.verdict == :approved && "bg-(--ok-bg) text-(--ok-text)",
                  d.verdict == :needs_work && "bg-(--warn-bg) text-(--warn-text)"
                ]}
              >
                <span class="font-medium">
                  {if d.verdict == :approved, do: "Approved", else: "Needs work"}
                </span>
                <span class="text-xs opacity-70">
                  by {d.by} at <span class="font-mono">{String.slice(d.head, 0, 7)}</span>, {ago(d.at)}
                </span>
                <p :if={d.body != ""} class="mt-1 whitespace-pre-wrap">{d.body}</p>
              </div>
            <% {:addressed, a} -> %>
              <div
                id={"addressed-#{a.short}"}
                class="rounded-lg bg-(--info-bg) px-3 py-2 text-sm text-(--info-text)"
              >
                <span class="font-medium">{a.by}</span>
                addressed it in
                <.link
                  patch={GitasticWeb.mr_path(@mr.branch) <> "?commit=" <> a.sha}
                  class="font-mono underline"
                >
                  {a.short}
                </.link>
                <span class="text-xs opacity-70">{ago(a.at)}</span>
                <p :if={a.note} class="mt-1 whitespace-pre-wrap">{a.note}</p>
              </div>
          <% end %>
        <% end %>

        <.form
          :if={not MergeRequest.done?(@mr)}
          for={@comment_form}
          id="comment-form"
          phx-submit="comment"
          class="space-y-2"
        >
          <textarea
            name={@comment_form[:body].name}
            id="comment-body"
            rows="3"
            placeholder="A general comment"
            class="w-full rounded-md border border-(--border) bg-(--surface) px-2 py-1.5 text-base focus:border-(--link) sm:text-sm focus:outline-none"
          >{@comment_form[:body].value}</textarea>
          <button class="rounded-md bg-(--surface) px-3 py-1.5 text-sm ring-1 ring-(--border) hover:bg-(--surface-2)">
            Comment
          </button>
        </.form>

        <.form
          :if={not MergeRequest.done?(@mr)}
          for={@decision_form}
          id="decision-form"
          phx-submit="decide"
          class="space-y-2 rounded-lg border border-(--border) bg-(--surface) p-3"
        >
          <h2 class="text-sm font-semibold text-(--text-2)">Decide</h2>
          <textarea
            name={@decision_form[:body].name}
            id="decision-body"
            rows="2"
            placeholder="A note with the decision (needed to reject)"
            class="w-full rounded-md border border-(--border) bg-(--surface) px-2 py-1.5 text-base focus:border-(--link) sm:text-sm focus:outline-none"
          >{@decision_form[:body].value}</textarea>
          <div class="flex gap-2">
            <button
              id="approve-button"
              name="verdict"
              value="approve"
              class="flex-1 rounded-md bg-(--ok-solid) px-4 py-2 text-sm font-medium text-white hover:opacity-90 sm:flex-none"
            >
              Approve
            </button>
            <button
              id="reject-button"
              name="verdict"
              value="reject"
              class="flex-1 rounded-md bg-(--surface) px-4 py-2 text-sm font-medium text-(--bad-text) ring-1 ring-(--bad-border) hover:bg-(--bad-bg) sm:flex-none"
            >
              Reject
            </button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  attr :comment, :map, required: true
  attr :addressed, :list, default: []
  attr :show_location, :boolean, default: false

  defp comment(assigns) do
    ~H"""
    <div class="text-sm">
      <div class="flex flex-wrap items-baseline gap-x-2 text-xs text-(--text-muted)">
        <span class="font-medium text-(--text)">{@comment.author}</span>
        <span :if={@show_location && @comment.path} class="font-mono">
          {@comment.path}:{@comment.line}{if @comment.side == "old", do: " (old)"}{if @comment.commit,
            do: " in " <> String.slice(@comment.commit, 0, 7)}
        </span>
        <span>{ago(@comment.at)}</span>
      </div>
      <p class="mt-0.5 whitespace-pre-wrap text-(--text)">{@comment.body}</p>
      <p :for={a <- @addressed} class="mt-1 text-xs text-(--info-text)">
        ↳ addressed in <span class="font-mono">{a.short}</span>{if a.note, do: ": " <> a.note}
      </p>
    </div>
    """
  end
end
