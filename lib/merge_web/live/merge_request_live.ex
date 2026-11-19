defmodule MergeWeb.MergeRequestLive do
  @moduledoc """
  One merge request: the diff of the branch against its base, file by file, the
  commits on the right (one commit's diff alone when clicked), comments on any
  line and in general, and Approve or Reject at the bottom. It follows the merge
  request's topic, so it updates when a commit is addressed or a decision lands.
  """

  use MergeWeb, :live_view

  alias Merge.{AutoMerge, Checks, Drift, Git, Groups, LiveStatus, MergeRequest, Queue, Servers}
  import MergeWeb.MergeRequestComponents

  # The queue's tabs. A tab dropping out never moves this page.
  on_mount MergeWeb.QueueHook
  on_mount MergeWeb.ServerSheetHook

  # How long "Approved" shows before the page moves on to the queue's next one.
  @moving_on_ms 1_500

  @impl true
  def mount(%{"branch" => parts}, _session, socket) do
    branch = Enum.join(parts, "/")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Merge.PubSub, MergeRequest.topic(branch))
      Phoenix.PubSub.subscribe(Merge.PubSub, Checks.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, Servers.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, AutoMerge.topic())
      Phoenix.PubSub.subscribe(Merge.PubSub, LiveStatus.topic())
    end

    mr =
      case MergeRequest.get(branch) do
        {:ok, mr} -> mr
        :error -> nil
      end

    {:ok,
     socket
     |> assign(branch: branch, mr: mr, picked: nil, page_title: (mr && mr.title) || branch)
     |> assign(tree: tree(mr, connected?(socket)))
     |> assign(line_form: blank_form(:line), review_form: blank_form(:review))
     |> assign(dialog: nil, dialog_error: nil, moving_to: nil)
     |> assign(hold: AutoMerge.hold_entry(branch))
     |> assign(live: LiveStatus.get(branch), last_look: mr && Map.get(mr, :looked))
     |> looking(mr)}
  end

  # The reviewer is looking: what they last looked at stays `last_look` for
  # this visit (the banner, and "Since you looked"), and the merge request
  # takes the head now as the next visit's. The work folder is read again at
  # once. Neither waits.
  defp looking(socket, mr) do
    if (connected?(socket) and mr) && not MergeRequest.done?(mr) do
      MergeRequest.looked(mr.branch)
      LiveStatus.poke()
    end

    socket
  end

  # The merge request's tree as the watcher last read the trees (every minute).
  # Reading them here asked git about every merge request's repo and every
  # server, twice a load. One not in that reading (opened since) has the
  # watcher read again, behind the page, which hears the answer.
  defp tree(nil, _connected?), do: nil

  defp tree(mr, connected?) do
    tree = Servers.tree_for(mr, Servers.current() || [])

    if tree == nil and connected? and Process.whereis(Merge.Watcher),
      do: Merge.Watcher.refresh()

    tree
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{mr: nil}} = socket) do
    _ = params

    {:noreply,
     assign(socket, view: :branch, files: [], groups: [], diff_error: nil, loaded: MapSet.new())}
  end

  def handle_params(params, _uri, socket) do
    view =
      cond do
        sha = params["commit"] -> {:commit, sha}
        params["since"] == "review" -> :since
        params["since"] == "look" and match?(%{head: _}, socket.assigns.last_look) -> :since_look
        true -> :branch
      end

    {:noreply, socket |> assign(view: view, picked: nil) |> load_files()}
  end

  @impl true
  def handle_info({:checks, _sha}, socket), do: {:noreply, main_checks(socket)}

  def handle_info(:more_files, %{assigns: %{mr: %{}}} = socket),
    do: {:noreply, more_files(socket)}

  def handle_info(:more_files, socket), do: {:noreply, socket}

  # For the queue's tabs (MergeWeb.QueueHook); this page follows its own topic.
  def handle_info(:merge_requests_changed, socket), do: {:noreply, socket}

  def handle_info(:auto_merge, socket),
    do: {:noreply, assign(socket, hold: AutoMerge.hold_entry(socket.assigns.branch))}

  # The diff is read again only when what it is made from moved: a comment or
  # a new body leaves the files as they are.
  def handle_info({:merge_request, mr}, socket) do
    old = socket.assigns.mr
    socket = assign(socket, mr: mr, page_title: mr.title)

    if old && diff_source(old) == diff_source(mr),
      do: {:noreply, assign_derived(socket)},
      else: {:noreply, load_files(socket)}
  end

  # Who is waiting, alone (an agent's wait started or ended).
  def handle_info({:waiting, names}, %{assigns: %{mr: %{} = mr}} = socket) do
    {:noreply, assign(socket, mr: %{mr | waiting: names})}
  end

  def handle_info({:waiting, _names}, socket), do: {:noreply, socket}

  # Approved with others waiting: on to the queue's Next as it is now (the one
  # named may have been decided meanwhile); with none left, the page stays.
  def handle_info(:move_on, socket) do
    socket = assign(socket, moving_to: nil)

    case Queue.next_after(socket.assigns.queue, socket.assigns.branch) do
      nil ->
        {:noreply, put_flash(socket, :info, "Approved.")}

      next ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved #{socket.assigns.mr.title}.")
         |> push_navigate(to: MergeWeb.mr_path(next.branch))}
    end
  end

  def handle_info({:live, live}, %{assigns: %{mr: %{}}} = socket),
    do: {:noreply, socket |> assign(live: live[socket.assigns.branch]) |> assign_derived()}

  def handle_info({:live, _live}, socket), do: {:noreply, socket}

  def handle_info({:servers, servers}, socket) do
    {:noreply, assign(socket, tree: Servers.tree_for(socket.assigns.mr, servers))}
  end

  @impl true
  def handle_event("pick", %{"path" => path, "side" => side, "line" => line}, socket) do
    {:noreply,
     assign(socket, picked: {path, side, String.to_integer(line)}, line_form: blank_form(:line))}
  end

  def handle_event("unpick", _params, socket), do: {:noreply, assign(socket, picked: nil)}

  # A file that starts folded was opened: its lines are sent now.
  def handle_event("open_file", %{"index" => index}, socket) do
    loaded = MapSet.put(socket.assigns[:loaded] || MapSet.new(), index)
    {:noreply, assign(socket, loaded: loaded)}
  end

  def handle_event("line_comment", %{"line" => %{"body" => body}}, socket) do
    {path, side, line} = socket.assigns.picked

    attrs = %{body: body, path: path, side: side, line: line, commit: view_commit(socket)}

    case MergeRequest.comment(socket.assigns.branch, attrs) do
      {:ok, _} -> {:noreply, assign(socket, picked: nil)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      :error -> {:noreply, gone(socket)}
    end
  end

  # The review bar: each action opens its own dialog. Comment and Reject have a
  # box (the draft is kept while they open and close); Approve only asks to be
  # sure, and carries no note.
  def handle_event("open_dialog", %{"dialog" => dialog}, socket)
      when dialog in ~w(comment approve reject) do
    {:noreply, assign(socket, dialog: String.to_existing_atom(dialog), dialog_error: nil)}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, dialog: nil, dialog_error: nil)}
  end

  def handle_event("draft", %{"review" => review}, socket) do
    {:noreply, assign(socket, review_form: to_form(review, as: :review))}
  end

  def handle_event("comment", %{"review" => %{"body" => body} = review}, socket) do
    MergeRequest.comment(socket.assigns.branch, %{body: body})
    |> reviewed(socket, review, "Commented.")
  end

  # With others waiting in the queue, the page says it's approved, then moves
  # on to the next one (:move_on); with none, it stays, as it always has.
  def handle_event("approve", _params, socket) do
    next = Queue.next_after(socket.assigns.queue, socket.assigns.branch)

    MergeRequest.decide(socket.assigns.branch, :approved)
    |> reviewed(assign(socket, moving_to: next), socket.assigns.review_form.params, "Approved.")
  end

  def handle_event("reject", %{"review" => %{"body" => body} = review}, socket) do
    MergeRequest.decide(socket.assigns.branch, :needs_work, body)
    |> reviewed(socket, review, "Sent back.")
  end

  # A refusal stays in the dialog, with the text as it was typed.
  defp reviewed({:ok, added}, socket, review, flash) do
    # Reloaded here so the new entry is on the page when the event lands.
    {:ok, mr} = MergeRequest.get(socket.assigns.branch)

    # An approval leaves a draft alone: it was never sent.
    review_form =
      if socket.assigns.dialog == :approve,
        do: to_form(review, as: :review),
        else: blank_form(:review)

    socket =
      socket
      |> assign(mr: mr, review_form: review_form, dialog: nil, dialog_error: nil)
      |> load_files()

    # Approved with another waiting: #moving-on says so, then :move_on.
    if socket.assigns.moving_to do
      Process.send_after(self(), :move_on, @moving_on_ms)
      {:noreply, socket}
    else
      {:noreply,
       socket |> push_event("review-sent", %{to: sent_to(added)}) |> put_flash(:info, flash)}
    end
  end

  defp reviewed({:error, message}, socket, review, _flash) do
    {:noreply,
     assign(socket,
       review_form: to_form(review, as: :review),
       dialog_error: message,
       moving_to: nil
     )}
  end

  defp reviewed(:error, socket, _review, _flash), do: {:noreply, gone(socket)}

  defp gone(socket) do
    socket |> put_flash(:error, "This merge request is gone.") |> push_navigate(to: ~p"/")
  end

  defp blank_form(name), do: to_form(%{"body" => ""}, as: name)

  # Approved, the page goes back to the top, where the badge says so; otherwise
  # to what was added.
  defp sent_to(%{verdict: :approved}), do: "top"
  defp sent_to(added), do: entry_id(added)

  # The DOM id of a comment or decision in the conversation.
  defp entry_id(%{verdict: _, round: round}), do: "decision-#{round}"
  defp entry_id(%{id: id}), do: "comment-#{id}"

  defp view_commit(%{assigns: %{view: {:commit, sha}}}), do: sha
  defp view_commit(_socket), do: nil

  defp last_decision(mr), do: List.last(mr.decisions)

  # What the files of any view are worked out from.
  defp diff_source(mr) do
    {mr.head, mr.merge_base, mr.commits, mr.files, Map.get(mr, :groups), Map.get(mr, :own_base),
     last_decision(mr)[:head]}
  end

  defp base_merges(mr), do: Enum.count(mr.commits, &MergeRequest.base_merge?/1)

  # What an empty diff means in each view.
  defp no_changes({:commit, _}, %{merge_of: base}, _moved) when is_binary(base),
    do: "Nothing of the author's: #{base} merged cleanly."

  defp no_changes(:since_look, _selected, _base),
    do: "Nothing of the author's since you looked."

  defp no_changes(:since, _selected, base) when is_binary(base),
    do: "Nothing of the author's since your review: #{base} merged in cleanly."

  defp no_changes(_view, _selected, _moved), do: "No changes."

  # The files for the current view. The branch diff is the process's cached one.
  defp load_files(%{assigns: %{mr: mr, view: view}} = socket) do
    result =
      case view do
        :branch ->
          {:ok, mr.files}

        {:commit, sha} ->
          case Enum.find(mr.commits, &(&1.sha == sha)) do
            nil ->
              {:error, "That commit is not on #{mr.branch}."}

            # A merge of the base shows only what the author did in it.
            commit ->
              if MergeRequest.base_merge?(commit),
                do: Git.remerge_diff(MergeRequest.git_repo(mr), sha),
                else: Git.commit_diff(MergeRequest.git_repo(mr), sha)
          end

        # Only the author's changes: what the base brought in drops out.
        :since ->
          case last_decision(mr) do
            nil ->
              {:ok, mr.files}

            d ->
              repo = MergeRequest.git_repo(mr)
              Git.since_diff(repo, MergeRequest.own_base(mr), d.head, mr.head)
          end

        # Only the author's changes since the reviewer last opened this page.
        :since_look ->
          repo = MergeRequest.git_repo(mr)
          Git.since_diff(repo, MergeRequest.own_base(mr), socket.assigns.last_look.head, mr.head)
      end

    case result do
      {:ok, files} -> assign(socket, files: files, groups: groups(socket, files), diff_error: nil)
      {:error, message} -> assign(socket, files: [], groups: [], diff_error: message)
    end
    |> start_files()
    |> assign_derived()
  end

  # How many lines of diff go to the browser in one piece: enough to fill a
  # few screens, little enough to build without the page stalling.
  @lines_at_once 400

  # The page goes first, with each file's name and counts; the files' lines
  # follow in order, a few at a time. Nothing is sent before the page is live.
  defp start_files(socket) do
    if connected?(socket), do: send(self(), :more_files)
    assign(socket, loaded: MapSet.new())
  end

  # The next files, in the order they read, up to `@lines_at_once` lines (one
  # file at least). One that starts folded waits until it is opened.
  defp more_files(%{assigns: %{groups: groups, loaded: loaded}} = socket) do
    waiting =
      groups
      |> Enum.flat_map(& &1.files)
      |> Enum.reject(&(MapSet.member?(loaded, &1.index) or starts_folded?(&1)))

    {now, _} =
      Enum.reduce_while(waiting, {[], 0}, fn file, {taken, lines} ->
        lines = lines + lines(file)

        if taken == [] or lines <= @lines_at_once,
          do: {:cont, {[file.index | taken], lines}},
          else: {:halt, {taken, lines}}
      end)

    if length(now) < length(waiting), do: send(self(), :more_files)
    assign(socket, loaded: MapSet.union(loaded, MapSet.new(now)))
  end

  # The files in groups: the author's, then the stack's, read at the view's tip
  # (and, for a deleted file, at the commit before it).
  defp groups(%{assigns: %{mr: mr, view: view} = assigns}, files) do
    {tip, before} =
      case view do
        :branch -> {mr.head, mr.merge_base || mr.base}
        {:commit, sha} -> {sha, sha <> "^"}
        :since -> {mr.head, last_decision(mr).head}
        :since_look -> {mr.head, assigns.last_look.head}
      end

    Groups.build(MergeRequest.git_repo(mr), files, tip, before, Map.get(mr, :groups))
  end

  defp assign_derived(%{assigns: %{mr: mr}} = socket) do
    commit = view_commit(socket)

    # By file, then by line, each with what it shows, so a file's piece gets
    # only its own and is sent again only when they change.
    line_comments =
      mr.comments
      |> Enum.filter(&(&1.path && &1.line && &1.commit == commit))
      |> Enum.map(fn comment ->
        %{
          comment: comment,
          addressed: addressed_for(mr, comment),
          seen_by: if(reply?(comment), do: [], else: MergeRequest.seen_by(mr, comment))
        }
      end)
      |> Enum.group_by(& &1.comment.path)
      |> Map.new(fn {path, entries} ->
        {path, Enum.group_by(entries, &{&1.comment.path, &1.comment.side, &1.comment.line})}
      end)

    # The commits after the reviewed head; the merges of the base among them
    # aren't the author's, so they aren't new, but they say the base moved.
    after_review =
      case last_decision(mr) do
        nil ->
          nil

        d ->
          mr.commits
          |> Enum.take_while(&(&1.sha != d.head))
          |> then(fn new -> if length(new) == length(mr.commits), do: [], else: new end)
      end

    new_since =
      after_review &&
        after_review |> Enum.reject(&MergeRequest.base_merge?/1) |> MapSet.new(& &1.sha)

    base_moved = after_review && Enum.find_value(after_review, &Map.get(&1, :merge_of))

    verdict = LiveStatus.verdict(mr, socket.assigns[:live])

    socket
    |> main_checks()
    |> assign(
      verdict: verdict,
      new_looked: MergeRequest.since_looked(mr, socket.assigns[:last_look]),
      line_comments: line_comments,
      new_since: new_since,
      base_moved: base_moved,
      selected: commit && Enum.find(mr.commits, &(&1.sha == commit))
    )
  end

  # Once merged, where main's checks stand, so the stream knows its merge is safe.
  defp main_checks(%{assigns: %{mr: %{merged: %{}} = mr}} = socket) do
    socket = assign(socket, pill: Checks.for_merge_request(mr, Drift.current()[:main]))

    with %{main: main} <- Drift.current(),
         pid when is_pid(pid) <- Process.whereis(Checks),
         true <- Checks.enabled?() do
      assign(socket, main_checks: {main, Checks.status(main)})
    else
      _ -> assign(socket, main_checks: nil)
    end
  end

  defp main_checks(socket), do: assign(socket, main_checks: nil, pill: nil)

  # The conversation, in order: comments, decisions and addressed commits.
  defp timeline(mr) do
    for(c <- mr.comments, !reply?(c), do: {:comment, c}) ++
      Enum.map(mr.decisions, &{:decision, &1}) ++
      Enum.map(mr.addressed, &{:addressed, &1})
  end

  defp sorted_timeline(mr), do: Enum.sort_by(timeline(mr), &elem(&1, 1).at, DateTime)

  defp replies_to(mr, comment),
    do: Enum.filter(mr.comments, &(Map.get(&1, :reply_to) == comment.id))

  defp addressed_for(mr, comment), do: Enum.filter(mr.addressed, &(&1.round == comment.round))

  @impl true
  def render(%{mr: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} queue={@queue} current={@branch}>
      <div id="not-found" class="rounded-lg border border-(--border) bg-(--surface) p-6 text-sm">
        <p>No open merge request for <span class="font-mono">{@branch}</span>.</p>
        <.link navigate={~p"/"} class="mt-3 inline-block text-(--link)">All merge requests</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    # The queue's next one after this, if any: Approve moves on to it.
    assigns = assign(assigns, :next, Queue.next_after(assigns.queue, assigns.branch))

    ~H"""
    <Layouts.app flash={@flash} queue={@queue} current={@branch}>
      <header id="mr-header" class="mb-4">
        <div class="flex items-start justify-between gap-3">
          <h1 class="text-lg font-semibold leading-snug">{@mr.title}</h1>
          <div class="flex shrink-0 items-center gap-1.5">
            <.merge_pill :if={not MergeRequest.done?(@mr)} mr={@mr} />
            <.checks_pill check={@pill} />
            <.live_badge :if={@verdict} verdict={@verdict} id="live-badge" />
            <.status :if={!@verdict} status={@mr.status} merged={@mr.merged} />
            <.queue_button
              :if={@mr.status in [:open, :in_progress]}
              branch={@mr.branch}
              queued={Enum.any?(@queue, &(&1.branch == @mr.branch))}
              class="ml-1 rounded-md border border-(--border) px-2 py-0.5"
            />
          </div>
        </div>
        <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-(--text-muted)">
          <span class="font-mono">{@mr.branch} → {@mr.base}</span>
          <span>opened by {@mr.opened_by} {ago(@mr.opened_at)}</span>
          <span
            :if={updated = Map.get(@mr, :body_updated_at)}
            id="body-updated"
            class="text-(--info-text)"
            title={DateTime.to_iso8601(updated)}
          >
            Body updated {ago(updated)}
          </span>
          <span id="agents">
            told: {Enum.join(@mr.agents, ", ")}
            <span :if={@mr.waiting != []} class="text-(--ok-text)">
              (waiting now: {Enum.join(@mr.waiting, ", ")})
            </span>
          </span>
          <span :if={@tree} id="mr-tree" class="inline-flex min-w-0 items-center gap-1.5">
            in <span class="font-mono">{@tree.name}</span>
            <.server tree={@tree} run={@dev_runs[@tree.path]} />
          </span>
          <span
            :if={@verdict && match?(%{site: %{state: :down}}, @live)}
            id="test-site-down"
            class="inline-flex items-center gap-1 font-medium text-(--bad-text)"
            title={@live.site.url}
          >
            <.icon name="hero-signal-slash-mini" class="size-3.5" /> Test site is down
            <span :if={@live.site.reason} class="font-normal">({@live.site.reason})</span>
          </span>
          <span :if={!@tree} id="mr-tree" class="text-(--text-faint)">no tree</span>
        </div>
        <%!-- What is in the way of a review, read from the work folder: the
             status file, unsaved changes, the test site. --%>
        <div
          :if={@verdict && @verdict.reasons != []}
          id="live-status"
          class={[
            "mt-2 rounded-md border px-3 py-2 text-sm",
            if(@verdict.tone == :down,
              do: "border-(--bad-border) bg-(--bad-bg) text-(--bad-text)",
              else: "border-(--warn-border) bg-(--warn-bg) text-(--warn-text)"
            ),
            @verdict.tone == :unsaid && "border-(--border)! bg-(--surface)! text-(--text-2)!"
          ]}
        >
          <p class="font-medium">Not ready to review</p>
          <.live_reasons verdict={@verdict} id="live-reasons" class="mt-1 text-sm" />
          <p
            :if={working = MergeRequest.working_note(@mr)}
            id="working-note"
            class="mt-1 text-xs opacity-80"
          >
            Put in progress by {working.by}, {ago(working.at)}
          </p>
        </div>
        <div
          :if={@mr.body != ""}
          id="mr-body"
          phx-hook=".Lightbox"
          class="markdown mt-3 max-w-3xl text-sm text-(--text-2)"
        >
          {Phoenix.HTML.raw(Merge.Body.to_html(@mr.body))}
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Lightbox">
          // Screenshots in the body open in an overlay: tap to zoom to full size
          // where you tapped (and pan), tap again to fit; arrows, keys or a swipe
          // go between them; Esc, ✕ or a tap beside the image closes it.
          export default {
            mounted() {
              this.onClick = (e) => {
                const img = e.target.closest("img")
                if (!img || !this.el.contains(img)) return
                e.preventDefault()
                const imgs = [...this.el.querySelectorAll("img")]
                this.open(imgs, imgs.indexOf(img))
              }
              this.el.addEventListener("click", this.onClick)
            },
            destroyed() {
              this.el.removeEventListener("click", this.onClick)
              this.close()
            },
            open(imgs, i) {
              this.close()
              const o = document.createElement("div")
              o.id = "lightbox"
              o.className = "lightbox"
              o.setAttribute("role", "dialog")
              o.setAttribute("aria-modal", "true")
              o.innerHTML = `
                <div class="lightbox-bar">
                  <span class="lightbox-name"></span>
                  <a class="lightbox-open" target="_blank" rel="noopener">Original</a>
                  <button type="button" class="lightbox-close" aria-label="Close">✕</button>
                </div>
                <div class="lightbox-stage"><img alt=""></div>
                <button type="button" class="lightbox-prev" aria-label="Previous">‹</button>
                <button type="button" class="lightbox-next" aria-label="Next">›</button>`
              document.body.appendChild(o)
              document.body.style.overflow = "hidden"
              this.overlay = o
              this.imgs = imgs
              const stage = o.querySelector(".lightbox-stage")
              stage.querySelector("img").addEventListener("click", (e) => {
                e.stopPropagation()
                this.toggleZoom(e)
              })
              stage.addEventListener("click", (e) => {
                if (e.target === stage && !o.classList.contains("zoomed")) this.close()
              })
              o.querySelector(".lightbox-close").onclick = () => this.close()
              o.querySelector(".lightbox-prev").onclick = () => this.show(this.i - 1)
              o.querySelector(".lightbox-next").onclick = () => this.show(this.i + 1)
              this.onKey = (e) => {
                if (e.key === "Escape") this.close()
                if (e.key === "ArrowLeft") this.show(this.i - 1)
                if (e.key === "ArrowRight") this.show(this.i + 1)
              }
              document.addEventListener("keydown", this.onKey)
              let x0 = null
              stage.addEventListener("touchstart", (e) => {
                x0 = e.touches.length === 1 ? e.touches[0].clientX : null
              }, {passive: true})
              stage.addEventListener("touchend", (e) => {
                if (x0 === null || o.classList.contains("zoomed")) return
                const dx = e.changedTouches[0].clientX - x0
                x0 = null
                if (Math.abs(dx) > 60) this.show(this.i + (dx < 0 ? 1 : -1))
              })
              this.show(i)
            },
            show(i) {
              const n = this.imgs.length
              this.i = (i + n) % n
              const from = this.imgs[this.i]
              const o = this.overlay
              const big = o.querySelector(".lightbox-stage img")
              o.classList.remove("zoomed")
              big.style.width = ""
              big.src = from.currentSrc || from.src
              big.alt = from.alt
              o.querySelector(".lightbox-name").textContent =
                n > 1 ? `${from.alt}  ${this.i + 1}/${n}` : from.alt
              o.querySelector(".lightbox-open").href = from.src
              o.querySelectorAll(".lightbox-prev, .lightbox-next").forEach((b) => (b.hidden = n < 2))
            },
            toggleZoom(e) {
              const o = this.overlay
              const stage = o.querySelector(".lightbox-stage")
              const big = stage.querySelector("img")
              if (o.classList.contains("zoomed")) {
                o.classList.remove("zoomed")
                big.style.width = ""
                return
              }
              const r = big.getBoundingClientRect()
              const fx = (e.clientX - r.left) / r.width
              const fy = (e.clientY - r.top) / r.height
              // Full size, and at least twice what fits, so small images zoom too.
              big.style.width = `${Math.max(big.naturalWidth, r.width * 2)}px`
              o.classList.add("zoomed")
              requestAnimationFrame(() => {
                stage.scrollLeft = fx * stage.scrollWidth - stage.clientWidth / 2
                stage.scrollTop = fy * stage.scrollHeight - stage.clientHeight / 2
              })
            },
            close() {
              if (!this.overlay) return
              this.overlay.remove()
              this.overlay = null
              document.body.style.overflow = ""
              document.removeEventListener("keydown", this.onKey)
            }
          }
        </script>
      </header>

      <.auto_merge_line
        :if={@mr.status == :approved}
        mr={@mr}
        hold={@hold}
        class="mb-4 rounded-lg border border-(--border) bg-(--surface) px-3 py-2 text-sm"
      />

      <p
        :if={@mr[:reading]}
        id="reading-branch"
        class="mb-4 flex items-center gap-2 rounded-lg border border-(--border) bg-(--surface) px-3 py-2 text-sm text-(--text-muted)"
      >
        <.icon name="hero-arrow-path" class="size-4 shrink-0 animate-spin" />
        Reading the branch. The commits and changes below fill in when it is done.
      </p>

      <div
        :if={not MergeRequest.done?(@mr) and match?(%{result: {:conflicts, _}}, @mr[:merge_check])}
        id="conflicts-banner"
        class="mb-4 rounded-lg border border-(--bad-border) bg-(--bad-bg) px-3 py-2 text-sm text-(--bad-text)"
      >
        <p class="font-medium">
          Conflicts with {@mr.merge_check.into}: this branch won't merge cleanly.
        </p>
        <ul class="mt-1 font-mono text-xs">
          <li :for={file <- elem(@mr.merge_check.result, 1)}>{file}</li>
        </ul>
        <p class="mt-1 text-xs">Merge main into the branch (or rebase it) and resolve these.</p>
      </div>

      <div
        :if={not MergeRequest.done?(@mr) and @mr[:branch_state] == :gone}
        id="branch-gone-banner"
        class="mb-4 rounded-lg border border-(--bad-border) bg-(--bad-bg) px-3 py-2 text-sm text-(--bad-text)"
      >
        The branch <span class="font-mono">{@mr.branch}</span>
        no longer exists. This is the last diff that was seen.
      </div>

      <div
        :if={not MergeRequest.done?(@mr) and match?({:rewritten, _}, @mr[:branch_state])}
        id="rewritten-banner"
        class="mb-4 rounded-lg border border-(--warn-border) bg-(--warn-bg) px-3 py-2 text-sm text-(--warn-text)"
      >
        The branch was rewritten: what was reviewed at
        <span class="font-mono">{elem(@mr.branch_state, 1)}</span>
        is no longer in it. The diff shows the branch as it is now; earlier comments may point at lines that moved.
      </div>

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

      <section :if={timeline(@mr) != []} id="conversation" class="mb-4 max-w-3xl space-y-3">
        <h2 class="text-sm font-semibold text-(--text-2)">Conversation</h2>
        <%= for item <- sorted_timeline(@mr) do %>
          <%= case item do %>
            <% {:comment, c} -> %>
              <div
                id={"comment-#{c.id}"}
                class="rounded-lg border border-(--border) bg-(--surface) px-3 py-2"
              >
                <.comment
                  comment={c}
                  addressed={[]}
                  replies={replies_to(@mr, c)}
                  seen_by={MergeRequest.seen_by(@mr, c)}
                  show_location
                />
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
                  patch={MergeWeb.mr_path(@mr.branch) <> "?commit=" <> a.sha}
                  class="font-mono underline"
                >
                  {a.short}
                </.link>
                <span class="text-xs opacity-70">{ago(a.at)}</span>
                <p :if={a.note} class="mt-1 whitespace-pre-wrap">{a.note}</p>
              </div>
          <% end %>
        <% end %>
      </section>

      <p
        :if={@base_moved}
        id="base-moved"
        class="mb-3 flex items-center gap-1.5 text-xs text-(--text-muted)"
      >
        <.icon name="hero-arrows-pointing-in" class="size-3.5 shrink-0 text-(--text-faint)" />
        <span>
          <span class="font-mono">{@base_moved}</span>
          has moved since your review; the branch has it merged in.
        </span>
      </p>

      <div
        :if={@new_looked != [] && @view != :since_look}
        id="since-looked"
        class="mb-4 rounded-lg border border-(--info-border) bg-(--info-bg) px-3 py-2 text-sm text-(--info-text)"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="font-medium">
            {count(@new_looked, "new commit")} since you last looked
            <span class="font-normal opacity-80">{ago(@last_look.at)}</span>
          </span>
          <.link
            id="since-looked-link"
            patch={MergeWeb.mr_path(@mr.branch) <> "?since=look"}
            class="font-medium underline"
          >
            Show what changed
          </.link>
        </div>
        <ul class="mt-1 space-y-0.5 text-xs">
          <li :for={c <- Enum.take(@new_looked, 5)} class="flex min-w-0 gap-2">
            <span class="shrink-0 font-mono opacity-70">{c.short}</span>
            <span class="min-w-0 truncate">{c.subject}</span>
          </li>
          <li :if={length(@new_looked) > 5} class="opacity-70">
            and {length(@new_looked) - 5} more
          </li>
        </ul>
      </div>

      <div
        :if={@new_since && MapSet.size(@new_since) > 0 && @view != :since && !@last_look}
        id="since-review"
        class="mb-4 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-(--warn-border) bg-(--warn-bg) px-3 py-2 text-sm text-(--warn-text)"
      >
        <span>
          {count(MapSet.size(@new_since), "new commit")} since your last review.
        </span>
        <.link
          patch={MergeWeb.mr_path(@mr.branch) <> "?since=review"}
          class="font-medium underline"
        >
          Show what changed
        </.link>
      </div>

      <div class="flex flex-col gap-4 lg:grid lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start lg:gap-5">
        <aside
          id="commits-panel"
          class="overflow-hidden rounded-lg border border-(--border) bg-(--surface) lg:sticky lg:top-4 lg:order-last lg:max-h-[calc(100vh-2rem)] lg:overflow-y-auto"
        >
          <details :if={length(@groups) > 1} id="outline" class="border-b border-(--border)">
            <summary class="flex cursor-pointer list-none items-center justify-between bg-(--surface-2) px-3 py-2 text-xs font-medium text-(--text-2)">
              <span>{count(@files, "file")} in {count(@groups, "group")}</span>
              <span class="text-(--text-faint)">▾</span>
            </summary>
            <ol id="outline-groups" phx-hook=".Outline" class="divide-y divide-(--border) text-xs">
              <li :for={group <- @groups} class="px-3 py-1.5">
                <a href={"#" <> group.id} class="flex items-center gap-2 text-(--text)">
                  <span class="min-w-0 flex-1 truncate font-medium">{group.title}</span>
                  <span class="text-(--text-faint)">{length(group.files)}</span>
                </a>
                <ol class="mt-0.5">
                  <li :for={{label, file} <- Groups.labels(group.files)}>
                    <a
                      href={"#file-#{file.index}"}
                      title={file.path}
                      class="block truncate font-mono text-(--text-muted) hover:text-(--text)"
                    >
                      {label}
                    </a>
                  </li>
                </ol>
              </li>
            </ol>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".Outline">
              // A file in the outline opens the group and the file it points at
              // before scrolling there: a folded one has nothing to scroll to.
              export default {
                mounted() {
                  this.el.addEventListener("click", e => {
                    const link = e.target.closest("a[href^='#']")
                    const target = link && document.getElementById(link.getAttribute("href").slice(1))
                    if (!target) return
                    e.preventDefault()
                    for (let el = target; el; el = el.parentElement) {
                      if (el.tagName === "DETAILS") el.open = true
                    }
                    target.scrollIntoView({block: "start"})
                  })
                }
              }
            </script>
          </details>
          <div class="flex items-center justify-between border-b border-(--border) bg-(--surface-2) px-3 py-2 text-xs font-medium text-(--text-2)">
            <span>{count(MergeRequest.own_commits(@mr), "commit")}, newest first</span>
            <span :if={base_merges(@mr) > 0} id="base-merges-count" class="text-(--text-faint)">
              {count(base_merges(@mr), "merge")} of {@mr.commits
              |> Enum.find_value(&Map.get(&1, :merge_of))}
            </span>
          </div>
          <div class="max-h-56 overflow-y-auto lg:max-h-none">
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
              patch={MergeWeb.mr_path(@mr.branch)}
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
              patch={MergeWeb.mr_path(@mr.branch) <> "?since=review"}
              class={[
                "rounded-md px-2.5 py-1",
                (@view == :since && "bg-(--btn-bg) text-(--btn-text)") ||
                  "bg-(--surface) text-(--text-2) ring-1 ring-(--border)"
              ]}
            >
              Since your review
            </.link>
            <.link
              :if={@last_look && @last_look.head != @mr.head}
              id="since-look-tab"
              patch={MergeWeb.mr_path(@mr.branch) <> "?since=look"}
              class={[
                "rounded-md px-2.5 py-1",
                (@view == :since_look && "bg-(--btn-bg) text-(--btn-text)") ||
                  "bg-(--surface) text-(--text-2) ring-1 ring-(--border)"
              ]}
            >
              Since you looked
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
            {no_changes(@view, @selected, @base_moved)}
          </p>

          <%!-- Each file is a piece of its own: the page paints without the
               diff, the files follow a few at a time (`:more_files`), one that
               starts folded only when it is opened, and a comment or a picked
               line sends its own file again, not the diff. --%>
          <div id="diff-files">
            <.diff_group :for={group <- @groups} group={group} headed={length(@groups) > 1}>
              <.live_component
                :for={file <- group.files}
                module={MergeWeb.FileComponent}
                id={"file-piece-#{file.index}"}
                file={file}
                index={file.index}
                stacked={length(@groups) > 1}
                loaded={MapSet.member?(@loaded, file.index)}
                line_comments={Map.get(@line_comments, file.path, %{})}
                picked={if(@picked && elem(@picked, 0) == file.path, do: @picked)}
                form={if(@picked && elem(@picked, 0) == file.path, do: @line_form)}
                commentable={not MergeRequest.done?(@mr)}
              />
            </.diff_group>
          </div>
        </section>
      </div>

      <%!-- Always at hand at the bottom; .BottomSpace keeps the page's bottom
           clear by the bar's height, so the last file can scroll above it.
           Three plain actions, each with its own dialog, so a note typed for
           one can't go with another. Once approved only Comment is left: the
           verdict is on the page. Merged or closed, the bar goes. With others
           waiting in the queue, Approve moves on to the next one. --%>
      <div
        :if={not MergeRequest.done?(@mr) and is_nil(@moving_to)}
        id="review-bar"
        phx-hook=".BottomSpace"
        class="fixed inset-x-0 bottom-0 z-40 border-t border-(--border) bg-(--surface)/95 pb-[env(safe-area-inset-bottom)] backdrop-blur"
      >
        <div
          id="review-actions"
          phx-hook=".ReviewSent"
          class="mx-auto flex max-w-7xl items-center gap-2 px-4 py-2 sm:justify-end lg:px-6"
        >
          <span
            :if={String.trim(@review_form[:body].value || "") != ""}
            id="review-draft"
            class="mr-auto hidden text-xs text-(--text-muted) sm:inline"
          >
            Draft kept
          </span>
          <button
            id="comment-button"
            type="button"
            phx-click="open_dialog"
            phx-value-dialog="comment"
            class="flex-1 rounded-md bg-(--surface) px-3 py-2.5 text-sm text-(--text) ring-1 ring-(--border) transition hover:bg-(--surface-2) active:scale-[0.98] sm:flex-none sm:py-2"
          >
            Comment
          </button>
          <button
            :if={@mr.status != :approved}
            id="approve-button"
            type="button"
            phx-click="open_dialog"
            phx-value-dialog="approve"
            class="flex-1 rounded-md bg-(--ok-solid) px-4 py-2.5 text-sm font-medium whitespace-nowrap text-white transition hover:opacity-90 active:scale-[0.98] sm:flex-none sm:py-2"
          >
            {if @next, do: "Approve, then next", else: "Approve"}
          </button>
          <button
            :if={@mr.status != :approved}
            id="reject-button"
            type="button"
            phx-click="open_dialog"
            phx-value-dialog="reject"
            class="flex-1 rounded-md bg-(--surface) px-4 py-2.5 text-sm font-medium text-(--bad-text) ring-1 ring-(--bad-border) transition hover:bg-(--bad-bg) active:scale-[0.98] sm:flex-none sm:py-2"
          >
            Reject
          </button>
        </div>
      </div>

      <.review_dialog :if={@dialog == :comment} id="comment-dialog" title="Comment">
        <.form
          for={@review_form}
          id="comment-form"
          phx-change="draft"
          phx-submit="comment"
          class="space-y-3"
        >
          <.review_box form={@review_form} placeholder="A comment on the whole merge request" />
          <p :if={@dialog_error} id="dialog-error" class="text-sm text-(--bad-text)">
            {@dialog_error}
          </p>
          <div class="flex gap-2 sm:justify-end">
            <button
              id="comment-send"
              class="flex-1 rounded-md bg-(--btn-bg) px-4 py-2.5 text-sm font-medium text-(--btn-text) transition hover:opacity-90 active:scale-[0.98] sm:flex-none sm:py-2"
            >
              Send
            </button>
          </div>
        </.form>
      </.review_dialog>

      <%!-- Approved, with another waiting: it says so where the bar was, then
           the page moves on (:move_on). --%>
      <div
        :if={@moving_to}
        id="moving-on"
        role="status"
        class="moving-on fixed inset-x-0 bottom-0 z-40 border-t border-(--ok-border) bg-(--ok-bg) pb-[env(safe-area-inset-bottom)]"
      >
        <div class="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 text-sm lg:px-6">
          <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-(--ok-solid) text-white">
            <.icon name="hero-check-micro" class="size-4" />
          </span>
          <span class="min-w-0 flex-1">
            <span class="font-medium text-(--ok-text)">Approved.</span>
            <span class="text-(--text-muted)">
              On to <span class="font-medium text-(--text)">{@moving_to.title}</span>…
            </span>
          </span>
        </div>
        <div class="moving-on-progress h-0.5 bg-(--ok-solid)"></div>
      </div>

      <.review_dialog :if={@dialog == :approve} id="approve-dialog" title={"Approve #{@mr.title}?"}>
        <p class="text-sm text-(--text-muted)">
          The author is told it is approved. An approval carries no note; a comment goes with Comment.
        </p>
        <p :if={@next} id="approve-next" class="mt-2 text-sm text-(--text-muted)">
          Then on to the next in your queue:
          <span class="font-medium text-(--text)">{@next.title}</span>
        </p>
        <div class="mt-4 flex gap-2 sm:justify-end">
          <button
            id="approve-cancel"
            type="button"
            phx-click="close_dialog"
            class="flex-1 rounded-md bg-(--surface) px-4 py-2.5 text-sm text-(--text) ring-1 ring-(--border) transition hover:bg-(--surface-2) active:scale-[0.98] sm:flex-none sm:py-2"
          >
            Cancel
          </button>
          <button
            id="approve-confirm"
            type="button"
            phx-click="approve"
            phx-disable-with="Approving…"
            class="flex-1 rounded-md bg-(--ok-solid) px-4 py-2.5 text-sm font-medium text-white transition hover:opacity-90 active:scale-[0.98] sm:flex-none sm:py-2"
          >
            {if @next, do: "Approve, then next", else: "Approve"}
          </button>
        </div>
      </.review_dialog>

      <.review_dialog :if={@dialog == :reject} id="reject-dialog" title="Send it back">
        <.form
          for={@review_form}
          id="reject-form"
          phx-change="draft"
          phx-submit="reject"
          class="space-y-3"
        >
          <.review_box
            form={@review_form}
            placeholder="What needs work (it can be left to this round's comments)"
          />
          <p :if={@dialog_error} id="dialog-error" class="text-sm text-(--bad-text)">
            {@dialog_error}
          </p>
          <div class="flex gap-2 sm:justify-end">
            <button
              id="reject-cancel"
              type="button"
              phx-click="close_dialog"
              class="flex-1 rounded-md bg-(--surface) px-4 py-2.5 text-sm text-(--text) ring-1 ring-(--border) transition hover:bg-(--surface-2) active:scale-[0.98] sm:flex-none sm:py-2"
            >
              Cancel
            </button>
            <button
              id="reject-send"
              class="flex-1 rounded-md bg-(--bad-text) px-4 py-2.5 text-sm font-medium text-white transition hover:opacity-90 active:scale-[0.98] sm:flex-none sm:py-2"
            >
              Send back
            </button>
          </div>
        </.form>
      </.review_dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReviewSent">
        // Once a comment or decision is in, show what was added; an approval
        // goes back to the top.
        export default {
          mounted() {
            this.handleEvent("review-sent", ({to}) => {
              if (to === "top") return window.scrollTo({top: 0, behavior: "smooth"})
              document.getElementById(to)?.scrollIntoView({behavior: "smooth", block: "center"})
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".BottomSpace">
        // Pads the page by the bar's height, kept up to date as it changes size.
        export default {
          mounted() {
            this.observer = new ResizeObserver(() => {
              document.body.style.paddingBottom = `${this.el.offsetHeight + 16}px`
              // The dialogs sit just above the bar (.review-dialog in app.css).
              document.documentElement.style.setProperty("--review-bar-h", `${this.el.offsetHeight}px`)
            })
            this.observer.observe(this.el)
          },
          destroyed() {
            this.observer.disconnect()
            document.body.style.paddingBottom = ""
            document.documentElement.style.removeProperty("--review-bar-h")
          }
        }
      </script>
      <.server_sheet
        :if={@server_sheet}
        tree={@server_sheet}
        log={@server_log}
        runs={@dev_runs}
        error={@server_error}
      />
    </Layouts.app>
    """
  end

  # A dialog over the page: a sheet from the bottom on a phone; on a wider
  # screen a card just above the review bar, at its right, by the buttons.
  # Escape, ✕ or a tap beside it closes it without sending.
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp review_dialog(assigns) do
    ~H"""
    <dialog
      id={@id}
      phx-hook=".ReviewDialog"
      phx-mounted={JS.ignore_attributes("open")}
      aria-labelledby={@id <> "-title"}
      class="review-dialog m-0 mt-auto w-full max-w-none rounded-t-2xl bg-(--surface) p-0 text-(--text) shadow-2xl sm:max-w-lg sm:rounded-xl"
    >
      <div class="px-4 pt-3 pb-[max(1rem,env(safe-area-inset-bottom))] sm:p-5">
        <div class="mb-3 flex items-start gap-3">
          <h2 id={@id <> "-title"} class="min-w-0 flex-1 text-base font-semibold break-words">
            {@title}
          </h2>
          <button
            type="button"
            phx-click="close_dialog"
            aria-label="Close"
            class="-mt-1 -mr-2 rounded-md p-2 text-(--text-muted) transition hover:bg-(--surface-2) hover:text-(--text)"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReviewDialog">
        // Opens as a modal (so the page behind can't be tapped). Escape and a tap
        // on the backdrop close it here at once, and tell the server.
        export default {
          mounted() {
            this.el.showModal()
            this.el.addEventListener("cancel", e => {
              e.preventDefault()
              this.dismiss()
            })
            this.el.addEventListener("click", e => {
              if (e.target === this.el) this.dismiss()
            })
          },
          dismiss() {
            this.el.close()
            this.pushEvent("close_dialog", {})
          }
        }
      </script>
    </dialog>
    """
  end

  attr :form, :map, required: true
  attr :placeholder, :string, required: true

  # The draft goes to the server when the box loses focus (closing the dialog
  # does that), not while typing: each update makes the browser walk the
  # whole diff, which on a phone stalled the keys being typed.
  defp review_box(assigns) do
    ~H"""
    <textarea
      name={@form[:body].name}
      id="review-body"
      rows="5"
      phx-debounce="blur"
      autofocus
      placeholder={@placeholder}
      class="block w-full resize-y rounded-md border border-(--border) bg-(--surface) px-3 py-2 text-base focus:border-(--link) focus:outline-none sm:text-sm"
    >{@form[:body].value}</textarea>
    """
  end
end
