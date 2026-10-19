defmodule GitasticWeb.DriftLive do
  @moduledoc "What local main has that GitHub hasn't: the diff origin/main...main."

  use GitasticWeb, :live_view

  alias Gitastic.{Drift, Git}
  import GitasticWeb.MergeRequestComponents

  @impl true
  def mount(_params, _session, socket) do
    repo = Drift.repo()

    files =
      with repo when is_binary(repo) <- repo,
           {:ok, files} <- Git.branch_diff(repo, "origin/main", "main") do
        files
      else
        _ -> []
      end

    {:ok,
     assign(socket,
       page_title: "main against GitHub",
       drift: Drift.read(repo),
       files: files
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="mb-4">
        <.link navigate={~p"/"} class="text-sm text-sky-700">← Merge requests</.link>
        <h1 class="mt-2 text-lg font-semibold">main against GitHub</h1>
        <p :if={@drift} class="mt-1 text-xs text-zinc-500">
          <span class="font-mono">origin/main...main</span>
          · {count(@drift.ahead, "commit")} ahead · {count(@drift.behind, "commit")} behind
        </p>
      </header>

      <div class="flex flex-col gap-4 lg:grid lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start lg:gap-5">
        <aside
          :if={@drift}
          class="overflow-hidden rounded-lg border border-zinc-200 bg-white lg:sticky lg:top-4 lg:order-last"
        >
          <div class="border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-medium text-zinc-600">
            Not on GitHub yet, newest first
          </div>
          <ol id="drift-commits" class="divide-y divide-zinc-100 text-sm">
            <li :for={c <- @drift.ahead} class="px-3 py-2">
              <span class="font-mono text-xs text-sky-700">{c.short}</span>
              <div class="text-zinc-800">{c.subject}</div>
              <div class="text-xs text-zinc-400">{c.author} · {ago(c.date)}</div>
            </li>
          </ol>
        </aside>

        <section id="diff" class="min-w-0 space-y-3">
          <p
            :if={@files == []}
            class="rounded-lg border border-zinc-200 bg-white px-3 py-4 text-sm text-zinc-500"
          >
            No changes: main is on GitHub.
          </p>
          <.diff_file :for={{file, i} <- Enum.with_index(@files)} file={file} index={i} />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
