defmodule GitasticWeb.MergeRequestComponents do
  @moduledoc "The pieces of the merge request pages: status, diff files and the commit list."

  use GitasticWeb, :html

  attr :status, :atom, required: true
  attr :merged, :map, default: nil, doc: "a merged merge request's merge commit"

  def status(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
      @status in [:open, :needs_work] && "bg-(--info-bg) text-(--info-text)",
      @status == :approved && "bg-(--ok-bg) text-(--ok-text)",
      @status == :merged && @merged && @merged.pushed && "bg-(--merged-bg) text-(--merged-text)",
      @status == :merged && !(@merged && @merged.pushed) && "bg-(--pending-bg) text-(--pending-text)",
      @status == :closed && "bg-(--surface-2) text-(--text-2)"
    ]}>
      {status_label(@status, @merged)}
    </span>
    """
  end

  def status_label(status, merged \\ nil)
  def status_label(:merged, %{pushed: true}), do: "On origin"
  def status_label(:merged, %{pushed: false}), do: "Merged"
  def status_label(status, _merged), do: base_label(status)

  defp base_label(:open), do: "Review"
  defp base_label(:approved), do: "Approved"
  # Sent back for work is still under review, as far as the badge goes.
  defp base_label(:needs_work), do: "Review"
  defp base_label(:merged), do: "Merged"
  defp base_label(:closed), do: "Closed"

  @doc "Where a merged merge request went: `Merged into main in abc1234: subject`."
  def merged_line(%{short: short, subject: subject}),
    do: "Merged into main in #{short}: #{subject}"

  @doc "The key a line comment is anchored to on the page."
  def line_key(path, %{type: :del, old: old}), do: {path, "old", old}
  def line_key(path, %{new: new}), do: {path, "new", new}

  attr :file, :map, required: true
  attr :index, :integer, required: true
  attr :line_comments, :map, default: %{}
  attr :picked, :any, default: nil
  attr :commentable, :boolean, default: false
  slot :comment_form
  slot :comment

  def diff_file(assigns) do
    lines = Enum.reduce(assigns.file.hunks, 0, &(length(&1.lines) + &2))
    assigns = assign(assigns, :open, lines <= 600)

    ~H"""
    <details
      id={"file-#{@index}"}
      open={@open}
      class="group overflow-hidden rounded-lg border border-(--border) bg-(--surface)"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 border-b border-(--border) bg-(--surface-2) px-3 py-2 text-xs">
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

      <div :if={@file.hunks != []} class="overflow-x-auto">
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
          patch={GitasticWeb.mr_path(@branch) <> "?commit=" <> c.sha}
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

  @doc "`3 files`, `1 file`."
  def count(n, word) when is_list(n), do: count(length(n), word)
  def count(1, word), do: "1 #{word}"
  def count(n, word), do: "#{n} #{word}s"

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
