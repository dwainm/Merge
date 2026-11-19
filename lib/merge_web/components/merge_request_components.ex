defmodule MergeWeb.MergeRequestComponents do
  @moduledoc "The pieces of the merge request pages: status, diff files and the commit list."

  use MergeWeb, :html

  attr :mr, :map, required: true
  attr :hold, :map, default: nil, doc: "what holds it, from Merge.AutoMerge.holds/0"
  attr :class, :string, default: "mt-1.5 text-xs"

  @doc """
  An approved merge request's line about Auto Merge: what holds it, in plain
  words, or that it is going into main.
  """
  def auto_merge_line(assigns) do
    ~H"""
    <p
      id={"auto-merge-#{@mr.branch}"}
      class={[
        "flex items-start gap-1.5",
        if(@hold, do: "text-(--warn-text)", else: "text-(--ok-text)"),
        @class
      ]}
      title={@hold && "Held since #{Calendar.strftime(@hold.at, "%H:%M")} UTC"}
    >
      <.icon
        name={if @hold, do: "hero-pause-circle-mini", else: "hero-arrow-path-mini"}
        class={["size-4 shrink-0", !@hold && "animate-spin [animation-duration:2s]"]}
      />
      <span :if={@hold}>
        <span class="font-medium">Not merging:</span> {Merge.AutoMerge.text(@hold.reason)}
      </span>
      <span :if={!@hold}>Merging into main</span>
    </p>
    """
  end

  attr :status, :atom, required: true
  attr :merged, :map, default: nil, doc: "a merged merge request's merge commit"

  def status(assigns) do
    ~H"""
    <span class={
      [
        "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
        # The reviewer's turn is blue, the author's amber.
        @status == :open && "bg-(--info-bg) text-(--info-text)",
        @status == :in_progress && "bg-(--warn-bg) text-(--warn-text)",
        @status == :approved && "bg-(--ok-bg) text-(--ok-text)",
        @status == :merged && @merged && @merged.pushed && "bg-(--merged-bg) text-(--merged-text)",
        @status == :merged && !(@merged && @merged.pushed) &&
          "bg-(--pending-bg) text-(--pending-text)",
        @status == :closed && "bg-(--surface-2) text-(--text-2)"
      ]
    }>
      {status_label(@status, @merged)}
    </span>
    """
  end

  attr :verdict, :map, required: true, doc: "Merge.LiveStatus.verdict/2 of an open merge request"
  attr :id, :string, default: nil

  @doc """
  An open merge request's badge, from what is true in its work folder: blue
  when it is the reviewer's turn (Ready to review, or Needs review when there
  is no folder to read), amber while it is being worked on or changed, red
  when its test site is down, grey when its status file says nothing.
  """
  def live_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-tone={@verdict.tone}
      class={[
        "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap transition-colors duration-300",
        @verdict.tone == :ready && "bg-(--info-bg) text-(--info-text)",
        @verdict.tone == :working && "bg-(--warn-bg) text-(--warn-text)",
        @verdict.tone == :down && "bg-(--bad-bg) text-(--bad-text)",
        @verdict.tone == :unsaid && "bg-(--surface-2) text-(--text-2)"
      ]}
    >
      {@verdict.label}
    </span>
    """
  end

  attr :verdict, :map, required: true
  attr :id, :string, required: true
  attr :class, :string, default: "mt-1.5 text-xs"

  @doc "What is in the way of a merge request that isn't ready, one short item each."
  def live_reasons(assigns) do
    ~H"""
    <ul
      :if={@verdict.reasons != []}
      id={@id}
      class={["flex flex-wrap items-center gap-x-3 gap-y-1", @class]}
    >
      <li
        :for={{kind, text} <- @verdict.reasons}
        data-kind={kind}
        class={["inline-flex min-w-0 items-center gap-1", reason_colour(kind)]}
      >
        <.icon name={reason_icon(kind)} class="size-3.5 shrink-0" />
        <span class="min-w-0 break-words">{text}</span>
      </li>
    </ul>
    """
  end

  defp reason_icon(:in_progress), do: "hero-wrench-mini"
  defp reason_icon(:changes), do: "hero-pencil-square-mini"
  defp reason_icon(:site_down), do: "hero-signal-slash-mini"
  defp reason_icon(:not_said), do: "hero-question-mark-circle-mini"

  defp reason_colour(:site_down), do: "font-medium text-(--bad-text)"
  defp reason_colour(:not_said), do: "text-(--text-muted)"
  defp reason_colour(_kind), do: "text-(--warn-text)"

  attr :branch, :string, required: true
  attr :queued, :boolean, required: true
  attr :class, :string, default: nil

  @doc "Add to queue, or (once queued) take it off. Handled by MergeWeb.QueueHook."
  def queue_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"queue-button-#{@branch}"}
      phx-click={if(@queued, do: "queue_remove", else: "queue_add")}
      phx-value-branch={@branch}
      title={if(@queued, do: "In your review queue: click to take it off", else: "Add to queue")}
      aria-label={if(@queued, do: "Take it off the queue", else: "Add to queue")}
      class={[
        "shrink-0 text-xs font-medium transition hover:bg-(--surface-2)",
        if(@queued, do: "text-(--info-text)", else: "text-(--text-muted) hover:text-(--text)"),
        @class
      ]}
    >
      {if(@queued, do: "✓", else: "+")}
      <span class="hidden sm:inline">
        {if(@queued, do: " Queued", else: " Queue")}
      </span>
    </button>
    """
  end

  def status_label(status, merged \\ nil)
  def status_label(:merged, %{pushed: true}), do: "On origin"
  def status_label(:merged, %{pushed: false}), do: "Merged"
  def status_label(status, _merged), do: base_label(status)

  defp base_label(:open), do: "Needs review"
  defp base_label(:in_progress), do: "In progress"
  defp base_label(:approved), do: "Approved"
  defp base_label(:merged), do: "Merged"
  defp base_label(:closed), do: "Closed"

  @doc "Where a merged merge request went: `Merged into main in abc1234: subject`."
  def merged_line(%{short: short, subject: subject}),
    do: "Merged into main in #{short}: #{subject}"

  @doc "The key a line comment is anchored to on the page."
  def line_key(path, %{type: :del, old: old}), do: {path, "old", old}
  def line_key(path, %{new: new}), do: {path, "new", new}

  @doc """
  A group of files (`Merge.Groups`): a slim heading that floats at the top of
  the viewport above the file headers while the group scrolls, with the
  author's note, the count and the +/−, folding the whole group. Without
  `headed` (one group: nothing to tell apart) the files come bare.
  """
  attr :group, :map, required: true
  attr :headed, :boolean, default: true
  slot :inner_block, required: true

  def diff_group(assigns) do
    ~H"""
    <details
      :if={@headed}
      id={@group.id}
      open
      phx-hook=".FileFold"
      data-path={"group " <> @group.title}
      class="group/g scroll-mt-4"
    >
      <summary class="sticky top-0 z-20 flex h-9 cursor-pointer list-none items-center gap-2 bg-(--bg) text-xs">
        <span class="text-(--text-faint) transition group-open/g:rotate-90">▸</span>
        <span class="font-medium text-(--text)">{@group.title}</span>
        <span
          :if={@group.note}
          class="min-w-0 flex-1 truncate text-(--text-muted)"
          title={@group.note}
        >
          {@group.note}
        </span>
        <span class="ml-auto whitespace-nowrap text-(--text-muted)">{count(@group.files, "file")}</span>
        <span class="font-mono text-(--ok-text)">+{@group.additions}</span>
        <span class="font-mono text-(--bad-text)">−{@group.deletions}</span>
      </summary>
      <div class="space-y-3 pt-1 pb-3">
        {render_slot(@inner_block)}
      </div>
    </details>
    <div :if={!@headed} class="space-y-3">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :file, :map, required: true
  attr :index, :integer, required: true
  attr :line_comments, :map, default: %{}
  attr :picked, :any, default: nil
  attr :commentable, :boolean, default: false

  attr :stacked, :boolean,
    default: false,
    doc: "under a group heading, which the header floats below"

  attr :loaded, :boolean,
    default: true,
    doc:
      "false while the file's lines are not sent yet: its name and counts show, with a line saying so"

  attr :form, :any, default: nil, doc: "the comment box's form, for the file with the picked line"

  def diff_file(assigns) do
    assigns = assign(assigns, :open, not starts_folded?(assigns.file))

    ~H"""
    <details
      id={"file-#{@index}"}
      open={@open}
      phx-hook=".FileFold"
      data-path={@file.path}
      data-index={@index}
      data-loaded={to_string(@loaded)}
      data-waits={to_string(not @open)}
      class={[
        "group rounded-lg border border-(--border) bg-(--surface)",
        if(@stacked, do: "scroll-mt-13", else: "scroll-mt-4")
      ]}
    >
      <%!-- The header floats at the top of the viewport (below the group's
           heading when there is one) while the file's diff scrolls under it,
           so a long file can be folded without scrolling back up. It stops
           floating when the file ends. The card cannot clip its overflow for
           that to work, so the corners are rounded here and on the diff body
           instead. --%>
      <summary class={[
        "sticky z-10 flex cursor-pointer list-none items-center gap-2 rounded-t-lg border-b border-(--border) bg-(--surface-2) px-3 py-2 text-xs group-[:not([open])]:rounded-b-lg",
        if(@stacked, do: "top-9", else: "top-0")
      ]}>
        <span class="text-(--text-faint) transition group-open:rotate-90">▸</span>
        <span class="min-w-0 flex-1 truncate font-mono text-(--text)" title={@file.path}>
          <span :if={@file.status == :renamed} class="text-(--text-faint)">{@file.old_path} → </span>{@file.path}
        </span>
        <span
          :if={@file.status in [:added, :deleted]}
          class={[
            "rounded px-1 font-medium",
            @file.status == :added && "bg-(--ok-bg) text-(--ok-text)",
            @file.status == :deleted && "bg-(--bad-bg) text-(--bad-text)"
          ]}
        >
          {if @file.status == :added, do: "new", else: "deleted"}
        </span>
        <span class="font-mono text-(--ok-text)">+{@file.additions}</span>
        <span class="font-mono text-(--bad-text)">−{@file.deletions}</span>
      </summary>

      <p :if={@file.binary?} class="px-3 py-2 text-xs text-(--text-muted)">Binary file</p>

      <%!-- Its lines are on their way (the files come in order behind the
           page), or are fetched now that it was opened. --%>
      <p
        :if={not @loaded and @file.hunks != []}
        id={"file-#{@index}-loading"}
        class="flex items-center gap-2 px-3 py-2 text-xs text-(--text-muted)"
      >
        <.icon name="hero-arrow-path" class="size-3.5 shrink-0 animate-spin" /> Loading the changes
      </p>

      <%!-- The browser lays out and styles only the files on screen: a long
           diff is a hundred thousand elements, and laying them all out took
           seconds on a phone each time anything moved (opening a dialog). --%>
      <div
        :if={@loaded and @file.hunks != []}
        class="overflow-x-auto rounded-b-lg [content-visibility:auto] [contain-intrinsic-size:auto_600px]"
      >
        <table class="hl code-diff w-full border-collapse font-mono text-[12px] leading-5">
          <tbody :for={hunk <- @file.hunks}>
            <tr class="diff-hunk">
              <td colspan="3" class="whitespace-pre px-3 py-0.5">{hunk.header}</td>
            </tr>
            <%= for line <- hunk.lines do %>
              <tr class={"diff-#{line.type}"}>
                <td
                  class={[
                    "diff-num w-px select-none whitespace-nowrap px-1.5 text-right align-top",
                    @commentable && line.type != :note &&
                      "diff-pick cursor-pointer"
                  ]}
                  phx-click={@commentable && line.type != :note && "pick"}
                  phx-value-path={@file.path}
                  phx-value-side={line_key(@file.path, line) |> elem(1)}
                  phx-value-line={line_key(@file.path, line) |> elem(2)}
                >
                  {line.old}
                </td>
                <td
                  class={[
                    "diff-num w-px select-none whitespace-nowrap px-1.5 text-right align-top",
                    @commentable && line.type != :note &&
                      "diff-pick cursor-pointer"
                  ]}
                  phx-click={@commentable && line.type != :note && "pick"}
                  phx-value-path={@file.path}
                  phx-value-side={line_key(@file.path, line) |> elem(1)}
                  phx-value-line={line_key(@file.path, line) |> elem(2)}
                >
                  {line.new}
                </td>
                <%!-- phx-no-format: whitespace here is the code's own. --%>
                <td class="diff-code whitespace-pre pr-4" phx-no-format><span class="diff-marker select-none">{marker(line.type)}</span>{code(line)}</td>
              </tr>
              <tr :for={comment <- comments_on(@line_comments, @file.path, line)}>
                <td
                  colspan="3"
                  class="border-y border-(--border) bg-(--surface-2) px-3 py-2 font-sans"
                >
                  <div class="sticky left-3 max-w-[calc(100vw-4rem)] lg:max-w-2xl">
                    <.comment
                      comment={comment.comment}
                      addressed={comment.addressed}
                      seen_by={comment.seen_by}
                    />
                  </div>
                </td>
              </tr>
              <tr :if={@picked && line.type != :note && @picked == line_key(@file.path, line)}>
                <td
                  colspan="3"
                  class="border-y border-(--border) bg-(--surface-2) px-3 py-2 font-sans"
                >
                  <div :if={@form} class="sticky left-3 max-w-[calc(100vw-4rem)] lg:max-w-2xl">
                    <.form
                      for={@form}
                      id="line-comment-form"
                      phx-submit="line_comment"
                      class="space-y-2"
                    >
                      <textarea
                        name={@form[:body].name}
                        id="line-comment-body"
                        rows="3"
                        phx-mounted={JS.focus()}
                        placeholder="Comment on this line"
                        class="w-full rounded-md border border-(--border) bg-(--surface) px-2 py-1.5 text-base focus:border-(--link) sm:text-sm focus:outline-none"
                      >{@form[:body].value}</textarea>
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
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FileFold">
      // A file folded or unfolded by hand stays that way across reloads: the
      // choice is kept per page and file path in localStorage, and put back
      // on mount and after each patch (which would otherwise restore the
      // server's default).
      //
      // Folding a file from its floating header, deep in a long diff, would
      // otherwise leave the page somewhere in the file after it; the page
      // scrolls back to the folded file instead.
      export default {
        mounted() {
          this.key = `merge:fold:${location.pathname}:${this.el.dataset.path}`
          this.restore()
          this.fetch()
          this.onToggle = () => {
            this.fetch()
            if (this.restoring) { this.restoring = false; return }
            try { localStorage.setItem(this.key, this.el.open ? "open" : "closed") } catch (_) {}
            if (!this.el.open && this.el.getBoundingClientRect().top < 0) {
              this.el.scrollIntoView({block: "start"})
            }
          }
          this.el.addEventListener("toggle", this.onToggle)
        },
        updated() { this.restore(); this.fetch() },
        // A file that starts folded has no lines on the page until it is
        // opened (the others come by themselves, in order): ask for them once.
        fetch() {
          const d = this.el.dataset
          if (d.loaded === "true") this.asked = false
          if (this.el.open && d.loaded === "false" && d.waits === "true" && !this.asked) {
            this.asked = true
            this.pushEvent("open_file", {index: Number(d.index)})
          }
        },
        destroyed() { this.el.removeEventListener("toggle", this.onToggle) },
        restore() {
          let kept = null
          try { kept = localStorage.getItem(this.key) } catch (_) {}
          if (kept === null) return
          const open = kept === "open"
          if (this.el.open !== open) {
            // The toggle this fires is not the reader's: nothing to keep or scroll to.
            this.restoring = true
            this.el.open = open
          }
        }
      }
    </script>
    """
  end

  @doc """
  True for a file whose diff starts folded: one nobody reads line by line
  (`Merge.Groups.quiet?/1`), or a very long one. Its lines are sent when it
  is opened.
  """
  def starts_folded?(file), do: Merge.Groups.quiet?(file) or lines(file) > 600

  @doc "How many lines a file's diff has."
  def lines(file), do: Enum.reduce(file.hunks, 0, &(length(&1.lines) + &2))

  @doc "True for an agent's answer to a comment."
  def reply?(comment), do: Map.get(comment, :reply_to) != nil

  attr :comment, :map, required: true
  attr :addressed, :list, default: []
  attr :replies, :list, default: []
  attr :seen_by, :list, default: []
  attr :show_location, :boolean, default: false

  @doc "One comment, with the commits that addressed it, who has seen it, and its replies."
  def comment(assigns) do
    ~H"""
    <div class="text-sm">
      <div class="flex flex-wrap items-baseline gap-x-2 text-xs text-(--text-muted)">
        <span :if={reply?(@comment)} class="text-(--text-faint)">↳</span>
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
      <p :if={@seen_by != []} class="mt-1 text-xs text-(--text-muted)">
        <.icon name="hero-eye-micro" class="size-3.5 align-[-2px]" />
        Seen by {Enum.join(@seen_by, ", ")}
      </p>
      <div
        :for={r <- @replies}
        id={"reply-#{r.id}"}
        class="mt-2 ml-4 rounded-md bg-(--surface-2) px-2.5 py-1.5"
      >
        <.comment comment={r} />
      </div>
    </div>
    """
  end

  defp comments_on(_comments, _path, %{type: :note}), do: []
  defp comments_on(comments, path, line), do: Map.get(comments, line_key(path, line), [])

  defp code(%{html: nil, text: text}), do: text
  defp code(%{html: html}), do: Phoenix.HTML.raw(html)

  defp marker(:add), do: "+"
  defp marker(:del), do: "-"
  defp marker(_), do: " "

  attr :commits, :list, required: true
  attr :selected, :string, default: nil
  attr :new_since, :any, default: nil, doc: "MapSet of shas new since the last review"
  attr :branch, :string, required: true

  def commit_list(assigns) do
    ~H"""
    <ol id="commits" class="divide-y divide-(--border) text-sm">
      <li :for={c <- @commits} id={"commit-#{c.short}"}>
        <%= if Map.get(c, :merge_of) do %>
          <.base_merge commit={c} branch={@branch} selected={@selected == c.sha} />
        <% else %>
          <.link
            patch={MergeWeb.mr_path(@branch) <> "?commit=" <> c.sha}
            class={[
              "block px-3 py-2 transition hover:bg-(--surface-2)",
              @selected == c.sha && "bg-(--info-bg)"
            ]}
          >
            <div class="flex items-center gap-2">
              <span class="font-mono text-xs text-(--link)">{c.short}</span>
              <span
                :if={@new_since && MapSet.member?(@new_since, c.sha)}
                class="rounded bg-(--warn-bg) px-1 text-[10px] font-medium uppercase text-(--warn-text)"
              >
                new
              </span>
            </div>
            <div class="mt-0.5 line-clamp-2 text-(--text)">{c.subject}</div>
            <div class="mt-0.5 text-xs text-(--text-faint)">{c.author} · {ago(c.date)}</div>
          </.link>
        <% end %>
      </li>
    </ol>
    """
  end

  attr :commit, :map, required: true
  attr :branch, :string, required: true
  attr :selected, :boolean, default: false

  # A merge of the base into the branch, folded to one quiet line: what it is,
  # how much the base brought, and whether the author had to resolve anything.
  # Its own view shows only that.
  defp base_merge(assigns) do
    ~H"""
    <.link
      patch={MergeWeb.mr_path(@branch) <> "?commit=" <> @commit.sha}
      id={"base-merge-#{@commit.short}"}
      title={@commit.subject}
      class={[
        "flex items-start gap-2 px-3 py-1.5 text-xs text-(--text-muted) transition hover:bg-(--surface-2)",
        @selected && "bg-(--info-bg)"
      ]}
    >
      <.icon
        name="hero-arrows-pointing-in"
        class="mt-px size-3.5 shrink-0 text-(--text-faint)"
      />
      <span class="min-w-0 flex-1">
        <span class="block">
          Merged {@commit.merge_of} in<span class="sr-only">,</span>
        </span>
        <span class="flex flex-wrap items-center gap-x-1.5 text-(--text-faint)">
          <span>{count(@commit.from_base, "file")} from {@commit.merge_of}</span>
          <span
            :if={Map.get(@commit, :own_files, 0) > 0}
            title={"The author resolved #{count(@commit.own_files, "file")} by hand in this merge"}
            class="rounded bg-(--warn-bg) px-1 text-[10px] font-medium text-(--warn-text)"
          >
            {@commit.own_files} resolved
          </span>
        </span>
      </span>
      <span class="shrink-0 font-mono text-(--text-faint)">{@commit.short}</span>
    </.link>
    """
  end

  attr :tree, :map, required: true, doc: "a tree from Merge.Servers"
  attr :run, :map, default: nil, doc: "the tree's last Merge.DevScript run"
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  @doc """
  A tree's server: its rack, and its URL to tap or "no server". The rack is
  blue when the server answers, red with a cross when its pages error, orange
  when it doesn't answer (the reason on hover) and orange and dashed with none,
  and pink and blinking while a Restart, Reseed or Turn off runs (`rack/1`). Tapping the rack
  opens the server sheet.
  """
  def server(assigns) do
    ~H"""
    <span id={@id} class={["inline-flex min-w-0 items-center gap-1.5", @class]}>
      <button
        type="button"
        id={"rack-" <> dom_id(@tree.path)}
        phx-click="server_open"
        phx-value-path={@tree.path}
        title={rack_title(@tree, @run)}
        aria-label={"#{@tree.name}'s server: #{rack_title(@tree, @run)}"}
        class="-m-1 shrink-0 rounded-md p-1 transition hover:bg-(--surface-2) active:scale-90"
      >
        <.rack status={@tree.status} running={running?(@run)} />
      </button>
      <a
        :if={@tree.url}
        href={@tree.url}
        target="_blank"
        rel="noopener"
        class="min-w-0 truncate text-(--link) hover:underline"
      >
        {host(@tree.url)}
      </a>
      <span :if={!@tree.url} class="text-(--text-faint)">no server</span>
    </span>
    """
  end

  attr :status, :atom, required: true
  attr :running, :boolean, default: false
  attr :class, :string, default: "size-4"

  # A small rack of two units, drawn in currentColor so one colour sets it: blue
  # when it runs, orange when it doesn't. Up is blue, not green, so it never
  # reads as checks passed; an error is red like a failed check, but drawn as a
  # rack with a cross. Each state also draws differently, for someone who
  # can't tell the colours apart:
  #
  #   up             blue    both lights lit
  #   error          red     top light lit, a cross for the bottom one
  #   not answering  orange  both lights out (rings)
  #   off            orange  dashed outline, no lights
  #   running        pink    both lights lit, blinking in turn
  defp rack(assigns) do
    assigns = assign(assigns, :state, rack_state(assigns.status, assigns.running))

    ~H"""
    <svg
      viewBox="0 0 16 16"
      fill="none"
      aria-hidden="true"
      data-state={@state}
      class={[
        "rack block shrink-0",
        @class,
        @state == :running && "rack-running",
        rack_colour(@state)
      ]}
    >
      <g
        stroke="currentColor"
        stroke-width="1.5"
        stroke-dasharray={if(@state == :off, do: "2.2 1.6")}
      >
        <rect x="1.75" y="1.75" width="12.5" height="5" rx="1.25" />
        <rect x="1.75" y="9.25" width="12.5" height="5" rx="1.25" />
      </g>
      <g :if={@state != :off} stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
        <path d="M8.5 4.25h3M8.5 11.75h3" />
      </g>
      <%= case @state do %>
        <% :off -> %>
        <% :error -> %>
          <circle cx="4.75" cy="4.25" r="1.25" fill="currentColor" />
          <path
            d="M3.85 10.85l1.8 1.8M5.65 10.85l-1.8 1.8"
            stroke="currentColor"
            stroke-width="1.25"
            stroke-linecap="round"
          />
        <% :not_answering -> %>
          <circle cx="4.75" cy="4.25" r="1" stroke="currentColor" stroke-width="1" />
          <circle cx="4.75" cy="11.75" r="1" stroke="currentColor" stroke-width="1" />
        <% _lit -> %>
          <circle class="rack-light" cx="4.75" cy="4.25" r="1.25" fill="currentColor" />
          <circle class="rack-light" cx="4.75" cy="11.75" r="1.25" fill="currentColor" />
      <% end %>
    </svg>
    """
  end

  # The rack's colour, which the sheet's status line wears too.
  defp rack_colour(:running), do: "text-(--pending-text)"
  defp rack_colour(:up), do: "text-(--info-text)"
  defp rack_colour(:error), do: "text-(--bad-text)"
  defp rack_colour(:not_answering), do: "text-(--stopped-text)"
  defp rack_colour(:off), do: "text-(--stopped-text)"

  defp rack_state(_status, true), do: :running
  defp rack_state(status, false) when status in [:up, :error, :not_answering], do: status
  defp rack_state(_status, false), do: :off

  defp running?(run), do: match?(%{state: :running}, run)

  # The rack's hover: the status, or the action while one runs.
  defp rack_title(tree, %{state: :running, action: action}) do
    verb = %{restart: "Restarting", reseed: "Reseeding", off: "Turning off"}[action]
    "#{verb}… (#{status_text(tree)})"
  end

  defp rack_title(tree, _run), do: status_text(tree)

  @doc "What the rack says: Up, Error: CompileError, Not answering, No server."
  def status_text(%{status: :up}), do: "Up"
  def status_text(%{status: :error, reason: reason}), do: "Error: #{reason}"
  def status_text(%{status: :not_answering}), do: "Not answering"
  def status_text(_), do: "No server"

  defp dom_id(path), do: path |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  attr :tree, :map, required: true, doc: "the open sheet's tree (ServerSheetHook)"
  attr :log, :list, default: nil
  attr :runs, :map, required: true
  attr :error, :string, default: nil

  @doc """
  The sheet a rack opens: the tree, its status and reason, the last lines of its
  log, and Restart, Reseed, Turn off. Each asks once, then runs the tree's
  `bin/dev`; the sheet says how it went.
  """
  def server_sheet(assigns) do
    assigns =
      assigns
      |> assign(:run, assigns.runs[assigns.tree.path])
      |> assign(:actions?, assigns.tree.dev? and assigns.tree.status != :off)

    ~H"""
    <dialog
      id="server-sheet"
      phx-hook=".ServerSheet"
      phx-mounted={JS.ignore_attributes("open")}
      aria-labelledby="server-sheet-title"
      class="review-dialog m-0 mt-auto w-full max-w-none rounded-t-2xl bg-(--surface) p-0 text-(--text) shadow-2xl sm:m-auto sm:max-w-xl sm:rounded-xl"
    >
      <div class="px-4 pt-3 pb-[max(1rem,env(safe-area-inset-bottom))] sm:p-5">
        <div class="mb-3 flex items-start gap-3">
          <h2 id="server-sheet-title" class="min-w-0 flex-1 text-base font-semibold break-words">
            {@tree.name}'s server
          </h2>
          <button
            type="button"
            phx-click="server_close"
            aria-label="Close"
            class="-mt-1 -mr-2 rounded-md p-2 text-(--text-muted) transition hover:bg-(--surface-2) hover:text-(--text)"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
          <dt class="text-(--text-muted)">Branch</dt>
          <dd class="min-w-0 truncate font-mono">{@tree.branch || "(detached)"}</dd>
          <dt class="text-(--text-muted)">URL</dt>
          <dd class="min-w-0 truncate">
            <a
              :if={@tree.url}
              href={@tree.url}
              target="_blank"
              rel="noopener"
              class="text-(--link) hover:underline"
            >
              {host(@tree.url)}
            </a>
            <span :if={!@tree.url} class="text-(--text-faint)">none</span>
          </dd>
          <dt class="text-(--text-muted)">Status</dt>
          <dd id="server-sheet-status" class="flex min-w-0 items-center gap-2">
            <.rack status={@tree.status} running={running?(@run)} />
            <span
              id="server-sheet-status-text"
              class={[
                "min-w-0 break-words",
                rack_colour(rack_state(@tree.status, running?(@run)))
              ]}
            >
              {status_text(@tree)}
            </span>
          </dd>
        </dl>

        <div
          :if={@run}
          id="server-sheet-run"
          class={[
            "mt-4 rounded-lg border px-3 py-2 text-sm transition-colors",
            case @run.state do
              :running -> "border-(--info-border) bg-(--info-bg) text-(--info-text)"
              :ok -> "border-(--ok-border) bg-(--ok-bg) text-(--ok-text)"
              :failed -> "border-(--bad-border) bg-(--bad-bg) text-(--bad-text)"
            end
          ]}
        >
          <p class="flex items-center gap-2">
            <.icon :if={@run.state == :running} name="hero-arrow-path" class="size-4 animate-spin" />
            <span>{run_text(@run)}</span>
          </p>
          <%!-- column-reverse opens it scrolled to the last line --%>
          <div
            :if={@run.output != []}
            class="mt-2 flex max-h-40 flex-col-reverse overflow-auto rounded bg-(--surface) p-2"
          >
            <pre
              id="server-sheet-output"
              class="font-mono text-[11px] leading-snug whitespace-pre-wrap break-all text-(--text-2)"
            >{Enum.join(@run.output, "\n")}</pre>
          </div>
        </div>

        <div :if={@log} class="mt-4">
          <h3 class="mb-1 text-xs text-(--text-muted)">
            Its log, the last {length(@log)} lines
          </h3>
          <div class="flex max-h-56 flex-col-reverse overflow-auto rounded-lg border border-(--border) bg-(--bg) p-2">
            <pre
              id="server-sheet-log"
              class="font-mono text-[11px] leading-snug whitespace-pre-wrap break-all text-(--text-2)"
            >{Enum.join(@log, "\n")}</pre>
          </div>
        </div>

        <p :if={@error} id="server-sheet-error" class="mt-3 text-sm text-(--bad-text)">{@error}</p>

        <div id="server-actions" class="mt-4 grid grid-cols-3 gap-2 sm:flex sm:justify-end">
          <button
            :for={
              {action, label, confirm} <- [
                {"restart", "Restart", "Restart #{@tree.name}'s server?"},
                {"reseed", "Reseed",
                 "Reseed #{@tree.name}? Its server stops, its database is dropped and set up again, and the server starts."},
                {"off", "Turn off", "Turn off #{@tree.name}'s server?"}
              ]
            }
            id={"server-#{action}"}
            type="button"
            phx-click="server_run"
            phx-value-action={action}
            data-confirm={confirm}
            disabled={not @actions? or running?(@run)}
            class={[
              "rounded-md px-4 py-2.5 text-sm font-medium ring-1 transition active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40 disabled:active:scale-100 sm:py-2",
              if(action == "off",
                do: "text-(--bad-text) ring-(--bad-border) enabled:hover:bg-(--bad-bg)",
                else: "text-(--text) ring-(--border) enabled:hover:bg-(--surface-2)"
              )
            ]}
          >
            {label}
          </button>
        </div>
        <p :if={not @tree.dev?} id="server-no-script" class="mt-2 text-xs text-(--text-muted)">
          This repo has no bin/dev, so Merge can't restart, reseed or turn off its servers.
        </p>
        <p
          :if={@tree.dev? and @tree.status == :off}
          id="server-off"
          class="mt-2 text-xs text-(--text-muted)"
        >
          No server is running in this tree; Merge doesn't start one.
        </p>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ServerSheet">
        // Opens as a modal. Escape and a tap on the backdrop close it here at
        // once, and tell the server.
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
            this.pushEvent("server_close", {})
          }
        }
      </script>
    </dialog>
    """
  end

  defp run_text(%{state: :running, action: action, name: name}) do
    case action do
      :restart -> "Restarting #{name}'s server…"
      :reseed -> "Reseeding #{name}: stopping, setting up its database again, starting…"
      :off -> "Turning off #{name}'s server…"
    end
  end

  defp run_text(%{message: message, at: at}), do: "#{message} (#{ago(at)})"

  defp host(url), do: url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")

  attr :commit, :map, required: true
  attr :ahead, :list, required: true
  attr :checks, :any, required: true
  attr :image, :any, default: :off, doc: "Merge.Checks.image_status/1 of the commit"
  attr :landing, :any, default: nil, doc: "Merge.Drift.landing/2, nil when unknown"
  attr :busy, :atom, required: true

  @doc """
  The Push of one of the commits ahead of GitHub: GitHub's main moves to it and
  the ones above stay ahead; on the tip it is Push All. The confirmation says
  what goes, whether the commit's checks and image build passed, and whether
  the push will land; the page handles `push_to` with the sha.
  """
  def push_to(assigns) do
    assigns =
      assign(
        assigns,
        :all,
        match?([%{sha: sha} | _] when sha == assigns.commit.sha, assigns.ahead)
      )

    ~H"""
    <button
      id={"push-to-#{@commit.short}"}
      phx-click="push_to"
      phx-value-sha={@commit.sha}
      data-confirm={push_to_confirm(@ahead, @commit, @checks, @image, @landing)}
      disabled={@busy != nil}
      title={
        if @all, do: "Push main to GitHub", else: "Push main to GitHub only up to #{@commit.short}"
      }
      class="shrink-0 rounded bg-(--btn-bg) px-2 py-0.5 text-xs font-medium text-(--btn-text) hover:opacity-90 disabled:opacity-50"
    >
      {if @all, do: "Push All", else: "Push"}
    </button>
    """
  end

  # The confirmation lists what goes and what stays, how the commit's checks and image
  # build went, and whether GitHub will take it.
  def push_to_confirm(ahead, commit, checks, image \\ :off, landing \\ nil) do
    going = Enum.drop_while(ahead, &(&1.sha != commit.sha))
    staying = length(ahead) - length(going)
    lines = Enum.map_join(going, "\n", &"#{&1.short}  #{&1.subject}")

    head =
      if staying == 0,
        do: "Push #{count(going, "commit")} to GitHub? This deploys.",
        else:
          "Push #{count(going, "commit")} to GitHub, up to #{commit.short}? This deploys; " <>
            "#{count(staying, "commit")} above #{if staying == 1, do: "stays", else: "stay"} ahead."

    land = if landing, do: "\n\n" <> landing_text(landing), else: ""

    held =
      Enum.reject([held_by("checks", checks), held_by("image build", image)], &is_nil/1)

    passed =
      Enum.reject(
        [
          match?(%{ok: true}, checks) && "Checks passed on #{commit.short}.",
          match?(%{ok: true}, image) && "Image build passed.",
          image == :not_needed && "Image build not needed."
        ],
        &(!&1)
      )

    case {held, passed} do
      {[], []} ->
        head <> "\n\n" <> lines <> land

      {[], passed} ->
        head <> "\n\n" <> lines <> "\n\n" <> Enum.join(passed, " ") <> land

      {held, _} ->
        "#{commit.short}'s #{Enum.join(held, ", and its ")}. Push anyway? " <>
          "This deploys code that hasn't passed them.\n\n" <> lines <> land
    end
  end

  # Why a check holds a push back, or nil when it doesn't.
  defp held_by(_what, status) when status in [:off, :not_needed], do: nil
  defp held_by(_what, %{ok: true}), do: nil
  defp held_by(what, %{ok: false}), do: "#{what} FAILED"
  defp held_by("checks", {:running, _}), do: "checks are still running"
  defp held_by(what, {:running, _}), do: "#{what} is still running"
  defp held_by("checks", _), do: "checks haven't run"
  defp held_by(what, _), do: "#{what} hasn't run"

  @doc "Whether a push of main will land, in words (`Merge.Drift.landing/2`)."
  def landing_text(:lands), do: "Push will land."

  def landing_text({:behind, n}),
    do: "Push will be refused: GitHub has #{count(n, "commit")} you don't. Pull first."

  def landing_text({:refused, message}), do: "Push will be refused: " <> message

  @doc "Whether checks allow a push: passed, not needed, or there are none."
  def checks_passed?(:off), do: true
  def checks_passed?(:not_needed), do: true
  def checks_passed?(%{ok: ok}), do: ok
  def checks_passed?(_), do: false

  @doc "`3 files`, `1 file`."
  def count(n, word) when is_list(n), do: count(length(n), word)
  def count(1, word), do: "1 #{word}"
  def count(n, word), do: "#{n} #{word}s"

  attr :mr, :map, required: true

  @doc "Whether an open merge request merges into main cleanly; also a rewritten or deleted branch."
  def merge_pill(assigns) do
    assigns =
      assign(assigns,
        check: assigns.mr[:merge_check],
        branch_state: assigns.mr[:branch_state]
      )

    ~H"""
    <span
      :if={@branch_state == :gone}
      title="The branch no longer exists"
      class="shrink-0 rounded-full bg-(--bad-bg) px-2 py-0.5 text-xs font-medium text-(--bad-text)"
    >
      Branch gone
    </span>
    <span
      :if={match?({:rewritten, _}, @branch_state)}
      title="The branch was rewritten: what was reviewed is no longer in it"
      class="shrink-0 rounded-full bg-(--warn-bg) px-2 py-0.5 text-xs font-medium text-(--warn-text)"
    >
      Rewritten
    </span>
    <%= case @check do %>
      <% %{result: :clean, into: into} -> %>
        <span
          title={"Merges into #{into} without conflicts"}
          class="merge-pill shrink-0 rounded-full bg-(--ok-bg) px-2 py-0.5 text-xs font-medium text-(--ok-text)"
        >
          Merges cleanly
        </span>
      <% %{result: {:conflicts, files}, into: into} -> %>
        <span
          title={"Conflicts with #{into} in " <> Enum.join(files, ", ")}
          class="merge-pill shrink-0 rounded-full bg-(--bad-bg) px-2 py-0.5 text-xs font-medium text-(--bad-text)"
        >
          Conflicts
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  attr :check, :any, required: true, doc: "{sha, status} from Checks.for_merge_request/2, or nil"
  attr :link, :boolean, default: true, doc: "false inside something that is a link already"

  @doc "A merged merge request's check as a pill: green passed, red failed, yellow running."
  def checks_pill(%{check: nil} = assigns), do: ~H""
  def checks_pill(%{check: {_sha, :none}} = assigns), do: ~H""

  def checks_pill(assigns) do
    {sha, status} = assigns.check
    short = String.slice(sha, 0, 7)

    {mark, tone, title} =
      case status do
        %{ok: true} -> {"✓", "bg-(--ok-bg) text-(--ok-text)", "Checks passed on #{short}"}
        %{ok: false} -> {"✗", "bg-(--bad-bg) text-(--bad-text)", "Checks failed on #{short}"}
        _ -> {"●", "bg-(--warn-bg) text-(--warn-text)", "Checks running on #{short}"}
      end

    assigns = assign(assigns, sha: sha, mark: mark, tone: tone, title: title)

    ~H"""
    <.link
      :if={@link}
      navigate={"/checks/" <> @sha}
      title={@title}
      class={["checks-pill shrink-0 rounded-full px-2 py-0.5 text-xs font-medium", @tone]}
    >
      {@mark} Checks
    </.link>
    <span
      :if={!@link}
      title={@title}
      class={["checks-pill shrink-0 rounded-full px-2 py-0.5 text-xs font-medium", @tone]}
    >
      {@mark} Checks
    </span>
    """
  end

  attr :sha, :string, required: true
  attr :status, :any, required: true, doc: "Merge.Checks.status/1, or :off"
  attr :image, :any, default: :off, doc: "Merge.Checks.image_status/1, or :off"
  attr :lead, :string, default: nil, doc: "what comes before, e.g. \"main at\""
  attr :id, :string, default: "checks"
  attr :show_sha, :boolean, default: true, doc: "false when the commit is already named beside it"
  attr :class, :string, default: nil

  @doc """
  Where the checks of a commit stand, and its image build beside them when there
  is one, with the end of the log when they failed.
  """
  def checks_line(%{status: :off} = assigns), do: ~H""

  def checks_line(assigns) do
    assigns =
      assign(assigns,
        short: String.slice(assigns.sha, 0, 7),
        on_sha?: assigns.show_sha and is_nil(assigns.lead)
      )

    ~H"""
    <div id={@id} class={["min-w-0 max-w-full text-sm", @class]}>
      <p class="flex flex-wrap items-baseline gap-x-2">
        <span :if={@lead} class="text-(--text-muted)">{@lead} <span class="font-mono">{@short}</span>:</span>
        <%= case @status do %>
          <% %{ok: true} = r -> %>
            <span class="font-medium text-(--ok-text)">✓ Checks passed</span>
            <span :if={@on_sha?} class="text-(--text-muted)">on
            <span class="font-mono">{@short}</span></span>
            <span class="text-xs text-(--text-faint)">{took(r)}</span>
          <% %{ok: false} -> %>
            <span class="font-medium text-(--bad-text)">✗ Checks failed</span>
            <span :if={@on_sha?} class="text-(--text-muted)">on
            <span class="font-mono">{@short}</span></span>
          <% {:running, at} -> %>
            <span class="font-medium text-(--warn-text)">● Checks running</span>
            <span :if={@on_sha?} class="text-(--text-muted)">on
            <span class="font-mono">{@short}</span></span>
            <span class="text-xs text-(--text-faint)">started {ago(at)}</span>
          <% {:queued, _} -> %>
            <span class="font-medium text-(--warn-text)">Checks queued</span>
          <% :none -> %>
            <span class="text-(--text-muted)">Checks haven't run yet</span>
        <% end %>
        <span :if={@image != :off} id={@id <> "-image"} class="contents">
          <%= case @image do %>
            <% %{ok: true} = r -> %>
              <span class="font-medium text-(--ok-text)">✓ Image build passed</span>
              <span class="text-xs text-(--text-faint)">{took(r)}</span>
            <% %{ok: false} -> %>
              <span class="font-medium text-(--bad-text)">✗ Image build failed</span>
            <% {:running, at} -> %>
              <span class="font-medium text-(--warn-text)">● Image build running</span>
              <span class="text-xs text-(--text-faint)">started {ago(at)}</span>
            <% {:queued, _} -> %>
              <span class="font-medium text-(--warn-text)">Image build queued</span>
            <% :not_needed -> %>
              <span
                class="text-(--text-muted)"
                title="The tip changes nothing GitHub's Docker workflow watches"
              >
                Image build not needed
              </span>
            <% :none -> %>
              <span class="text-(--text-muted)">Image build hasn't run yet</span>
          <% end %>
        </span>
        <.link
          :if={@status != :none}
          navigate={"/checks/" <> @sha}
          class="text-xs text-(--link) underline"
        >
          log
        </.link>
      </p>
      <pre
        :if={match?(%{ok: false}, @status)}
        class="mt-2 max-h-48 overflow-auto rounded-md bg-(--bad-bg) p-2 text-xs text-(--text)"
      >{excerpt(@status)}</pre>
      <pre
        :if={match?(%{ok: false}, @image)}
        class="mt-2 max-h-48 overflow-auto rounded-md bg-(--bad-bg) p-2 text-xs text-(--text)"
      >{excerpt(@image)}</pre>
    </div>
    """
  end

  defp took(%{started_at: s, finished_at: f}) do
    seconds = DateTime.diff(f, s)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  # The step that failed (`Merge.Checks.Excerpt`); a result kept before there were
  # excerpts has only its last lines.
  defp excerpt(%{excerpt: excerpt}) when is_binary(excerpt), do: excerpt
  defp excerpt(%{log: log}), do: Merge.Checks.Excerpt.excerpt(log)

  @doc "A short relative time for an ISO 8601 string or a DateTime."
  def ago(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> ago(dt)
      _ -> iso
    end
  end

  def ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
