defmodule GitasticWeb.MergeRequestComponents do
  @moduledoc "The pieces of the merge request pages: status, diff files and the commit list."

  use GitasticWeb, :html

  attr :status, :atom, required: true

  def status(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
      @status == :open && "bg-sky-100 text-sky-800",
      @status == :approved && "bg-emerald-100 text-emerald-800",
      @status == :needs_work && "bg-amber-100 text-amber-800",
      @status == :merged && "bg-violet-100 text-violet-800",
      @status == :closed && "bg-zinc-200 text-zinc-700"
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  def status_label(:open), do: "In review"
  def status_label(:approved), do: "Approved"
  def status_label(:needs_work), do: "Needs work"
  def status_label(:merged), do: "Merged"
  def status_label(:closed), do: "Closed"

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
      class="group overflow-hidden rounded-lg border border-zinc-200 bg-white"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs">
        <span class="text-zinc-400 transition group-open:rotate-90">▸</span>
        <span class="min-w-0 flex-1 truncate font-mono text-zinc-800" title={@file.path}>
          <span :if={@file.status == :renamed} class="text-zinc-400">{@file.old_path} → </span>{@file.path}
        </span>
        <span
          :if={@file.status in [:added, :deleted]}
          class={[
            "rounded px-1 font-medium",
            @file.status == :added && "bg-emerald-100 text-emerald-800",
            @file.status == :deleted && "bg-rose-100 text-rose-800"
          ]}
        >
          {if @file.status == :added, do: "new", else: "deleted"}
        </span>
        <span class="font-mono text-emerald-700">+{@file.additions}</span>
        <span class="font-mono text-rose-700">−{@file.deletions}</span>
      </summary>

      <p :if={@file.binary?} class="px-3 py-2 text-xs text-zinc-500">Binary file</p>

      <div :if={@file.hunks != []} class="overflow-x-auto">
        <table class="hl w-full border-collapse font-mono text-[12px] leading-5">
          <tbody :for={hunk <- @file.hunks}>
            <tr class="bg-sky-50 text-zinc-500">
              <td colspan="3" class="whitespace-pre px-3 py-0.5">{hunk.header}</td>
            </tr>
            <%= for line <- hunk.lines do %>
              <tr class={[
                line.type == :add && "bg-emerald-50",
                line.type == :del && "bg-rose-50",
                line.type == :note && "text-zinc-400"
              ]}>
                <td
                  class={[
                    "w-px select-none whitespace-nowrap px-1.5 text-right align-top text-zinc-400",
                    @commentable && line.type != :note &&
                      "cursor-pointer hover:bg-sky-100 hover:text-sky-700"
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
                    "w-px select-none whitespace-nowrap border-r border-zinc-100 px-1.5 text-right align-top text-zinc-400",
                    @commentable && line.type != :note &&
                      "cursor-pointer hover:bg-sky-100 hover:text-sky-700"
                  ]}
                  phx-click={@commentable && line.type != :note && "pick"}
                  phx-value-path={@file.path}
                  phx-value-side={line_key(@file.path, line) |> elem(1)}
                  phx-value-line={line_key(@file.path, line) |> elem(2)}
                >
                  {line.new}
                </td>
                <%!-- phx-no-format: whitespace here is the code's own. --%>
                <td class="whitespace-pre pr-4 pl-2" phx-no-format><span class="select-none text-zinc-400">{marker(line.type)}</span>{code(line)}</td>
              </tr>
              <tr :for={comment <- comments_on(@line_comments, @file.path, line)}>
                <td colspan="3" class="border-y border-zinc-200 bg-zinc-50 px-3 py-2 font-sans">
                  <div class="sticky left-3 max-w-[calc(100vw-4rem)] lg:max-w-2xl">
                    {render_slot(@comment, comment)}
                  </div>
                </td>
              </tr>
              <tr :if={@picked && line.type != :note && @picked == line_key(@file.path, line)}>
                <td colspan="3" class="border-y border-zinc-200 bg-zinc-50 px-3 py-2 font-sans">
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
    <ol id="commits" class="divide-y divide-zinc-100 text-sm">
      <li :for={c <- @commits} id={"commit-#{c.short}"}>
        <.link
          patch={GitasticWeb.mr_path(@branch) <> "?commit=" <> c.sha}
          class={[
            "block px-3 py-2 transition hover:bg-zinc-50",
            @selected == c.sha && "bg-sky-50"
          ]}
        >
          <div class="flex items-center gap-2">
            <span class="font-mono text-xs text-sky-700">{c.short}</span>
            <span
              :if={@new_since && MapSet.member?(@new_since, c.sha)}
              class="rounded bg-amber-100 px-1 text-[10px] font-medium uppercase text-amber-800"
            >
              new
            </span>
          </div>
          <div class="mt-0.5 line-clamp-2 text-zinc-800">{c.subject}</div>
          <div class="mt-0.5 text-xs text-zinc-400">{c.author} · {ago(c.date)}</div>
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
