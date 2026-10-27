defmodule MergeWeb.MergeRequestComponents do
  @moduledoc "The pieces of the merge request pages: status, diff files and the commit list."

  use MergeWeb, :html

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

  attr :quiet, :boolean, default: false, doc: "starts folded: nobody reads it line by line"
  slot :comment_form
  slot :comment

  def diff_file(assigns) do
    lines = Enum.reduce(assigns.file.hunks, 0, &(length(&1.lines) + &2))
    assigns = assign(assigns, :open, lines <= 600 and not assigns.quiet)

    ~H"""
    <details
      id={"file-#{@index}"}
      open={@open}
      phx-hook=".FileFold"
      data-path={@file.path}
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

      <div :if={@file.hunks != []} class="overflow-x-auto rounded-b-lg">
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
                    {render_slot(@comment, comment)}
                  </div>
                </td>
              </tr>
              <tr :if={@picked && line.type != :note && @picked == line_key(@file.path, line)}>
                <td
                  colspan="3"
                  class="border-y border-(--border) bg-(--surface-2) px-3 py-2 font-sans"
                >
                  <div class="sticky left-3 max-w-[calc(100vw-4rem)] lg:max-w-2xl">
                    {render_slot(@comment_form)}
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
          this.onToggle = () => {
            if (this.restoring) { this.restoring = false; return }
            try { localStorage.setItem(this.key, this.el.open ? "open" : "closed") } catch (_) {}
            if (!this.el.open && this.el.getBoundingClientRect().top < 0) {
              this.el.scrollIntoView({block: "start"})
            }
          }
          this.el.addEventListener("toggle", this.onToggle)
        },
        updated() { this.restore() },
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
      </li>
    </ol>
    """
  end

  attr :tree, :map, required: true, doc: "a tree from Merge.Servers"
  attr :run, :map, default: nil, doc: "the tree's last Merge.DevScript run"
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  @doc """
  A tree's server: its dot, and its URL to tap or "no server". The dot is green
  when the server answers, red when its pages error or it doesn't answer (the
  reason on hover), grey with none, and pulses while a Restart, Reseed or Turn
  off runs. Tapping the dot opens the server sheet.
  """
  def server(assigns) do
    ~H"""
    <span id={@id} class={["inline-flex min-w-0 items-center gap-1.5", @class]}>
      <button
        type="button"
        id={"dot-" <> dom_id(@tree.path)}
        phx-click="server_open"
        phx-value-path={@tree.path}
        title={status_text(@tree)}
        aria-label={"#{@tree.name}'s server: #{status_text(@tree)}"}
        class="-m-1.5 shrink-0 rounded-full p-1.5 transition hover:bg-(--surface-2) active:scale-90"
      >
        <.dot status={@tree.status} running={running?(@run)} />
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
  attr :class, :string, default: "size-2.5"

  defp dot(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "block rounded-full",
        @class,
        case @status do
          :up -> "bg-(--ok-solid)"
          :off -> "bg-(--text-faint) opacity-50"
          _ -> "bg-(--bad-text)"
        end,
        @running && "animate-pulse ring-4 ring-(--info-bg)"
      ]}
    ></span>
    """
  end

  defp running?(run), do: match?(%{state: :running}, run)

  @doc "What the dot says: Up, Error: CompileError, Not answering, No server."
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
  The sheet a dot opens: the tree, its status and reason, the last lines of its
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
            <.dot status={@tree.status} running={running?(@run)} class="size-2.5 shrink-0" />
            <span class={[
              "min-w-0 break-words",
              @tree.status in [:error, :not_answering] && "text-(--bad-text)"
            ]}>
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
      >{last_lines(@status.log, 15)}</pre>
      <pre
        :if={match?(%{ok: false}, @image)}
        class="mt-2 max-h-48 overflow-auto rounded-md bg-(--bad-bg) p-2 text-xs text-(--text)"
      >{last_lines(@image.log, 15)}</pre>
    </div>
    """
  end

  defp took(%{started_at: s, finished_at: f}) do
    seconds = DateTime.diff(f, s)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp last_lines(log, n),
    do: log |> String.trim_trailing() |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n")

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
