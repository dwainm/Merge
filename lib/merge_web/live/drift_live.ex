defmodule MergeWeb.DriftLive do
  @moduledoc """
  What local main has that GitHub hasn't: the diff origin/main...main, or at
  `/drift/<sha>` only up to one of the commits ahead (what its Push would send).
  """

  use MergeWeb, :live_view

  alias Merge.{Drift, Git, Groups}
  import MergeWeb.MergeRequestComponents

  @impl true
  def mount(params, _session, socket) do
    repo = Drift.repo()
    drift = Drift.read(repo)
    to = commit(params["sha"], drift)

    files =
      with repo when is_binary(repo) <- repo,
           {:ok, files} <- Git.branch_diff(repo, "origin/main", to) do
        files
      else
        _ -> []
      end

    groups = if files == [], do: [], else: Groups.build(repo, files, to, "origin/main")

    {:ok,
     assign(socket,
       page_title: "main against GitHub",
       drift: drift,
       to: to,
       in_diff: in_diff(drift, to),
       files: files,
       groups: groups
     )}
  end

  # The commit the diff goes up to: one of those ahead when the URL names one, else main.
  defp commit(sha, %{ahead: ahead}) when is_binary(sha) do
    Enum.find_value(ahead, "main", &(String.starts_with?(&1.sha, sha) && &1.sha))
  end

  defp commit(_sha, _drift), do: "main"

  # The shas of the commits the diff covers: those from `to` down.
  defp in_diff(%{ahead: ahead}, "main"), do: MapSet.new(ahead, & &1.sha)

  defp in_diff(%{ahead: ahead}, to),
    do: ahead |> Enum.drop_while(&(&1.sha != to)) |> MapSet.new(& &1.sha)

  defp in_diff(_drift, _to), do: MapSet.new()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="mb-4">
        <.link navigate={~p"/"} class="text-sm text-(--link)">← Merge requests</.link>
        <h1 class="mt-2 text-lg font-semibold">
          main<span :if={@to != "main"}> up to {String.slice(@to, 0, 7)}</span> against GitHub
        </h1>
        <p :if={@drift} class="mt-1 text-xs text-(--text-muted)">
          <span class="font-mono">origin/main...{if @to == "main",
            do: "main",
            else: String.slice(@to, 0, 7)}</span>
          · {count(@drift.ahead, "commit")} ahead · {count(@drift.behind, "commit")} behind
        </p>
      </header>

      <div class="flex flex-col gap-4 lg:grid lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start lg:gap-5">
        <aside
          :if={@drift}
          class="overflow-hidden rounded-lg border border-(--border) bg-(--surface) lg:sticky lg:top-4 lg:order-last"
        >
          <div class="border-b border-(--border) bg-(--surface-2) px-3 py-2 text-xs font-medium text-(--text-2)">
            Not on GitHub yet, newest first
          </div>
          <%!-- Each commit links to the diff up to it; the ones above the current one are dimmed. --%>
          <ol id="drift-commits" class="divide-y divide-(--border) text-sm">
            <li
              :for={c <- @drift.ahead}
              id={"drift-commit-#{c.short}"}
              class={["px-3 py-2", not MapSet.member?(@in_diff, c.sha) && "opacity-50"]}
            >
              <.link
                navigate={~p"/drift/#{c.sha}"}
                class="font-mono text-xs text-(--link) hover:underline"
              >
                {c.short}
              </.link>
              <div class="text-(--text)">{c.subject}</div>
              <div class="text-xs text-(--text-faint)">{c.author} · {ago(c.date)}</div>
            </li>
          </ol>
        </aside>

        <section id="diff" class="min-w-0 space-y-3">
          <p
            :if={@files == []}
            class="rounded-lg border border-(--border) bg-(--surface) px-3 py-4 text-sm text-(--text-muted)"
          >
            No changes: main is on GitHub.
          </p>
          <.diff_group :for={group <- @groups} group={group} headed={length(@groups) > 1}>
            <.diff_file
              :for={file <- group.files}
              file={file}
              index={file.index}
              stacked={length(@groups) > 1}
              quiet={Groups.quiet?(file)}
            />
          </.diff_group>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
