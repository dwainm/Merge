defmodule MergeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MergeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :queue, :list, default: nil, doc: "the review queue's tabs, from MergeWeb.QueueHook"
  attr :current, :string, default: nil, doc: "the branch on screen, whose tab is marked"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-(--border) bg-(--surface)">
      <div class="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 lg:px-6">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 font-mono text-sm font-semibold tracking-tight text-(--text)"
        >
          <img src={~p"/images/logo.svg"} alt="" class="h-5 w-5" /> Merge
        </.link>
        <span class="text-xs text-(--text-faint)">the easy workflow for Elixir projects</span>
      </div>
    </header>

    <.queue_tabs :if={@queue not in [nil, []]} tabs={@queue} current={@current} />

    <main class="mx-auto max-w-7xl px-4 py-5 lg:px-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :tabs, :list, required: true
  attr :current, :string, default: nil

  # The review queue as tabs: the first still in review is Next; an approved,
  # merged or closed one fades out over a few seconds and drops away.
  defp queue_tabs(assigns) do
    ~H"""
    <nav id="review-queue" class="border-b border-(--border) bg-(--surface)" aria-label="Review queue">
      <div class="mx-auto flex max-w-7xl items-end gap-1 overflow-x-auto px-4 pt-2 lg:px-6">
        <div
          :for={tab <- @tabs}
          id={"queue-tab-#{tab.branch}"}
          class={
            [
              "group relative -mb-px flex max-w-[18rem] shrink-0 items-center rounded-t-lg border border-(--border) text-sm transition-colors",
              # The tab on screen is the page's colour and opens into it.
              tab.branch == @current && "z-10 border-b-(--bg) bg-(--bg) font-medium text-(--text)",
              tab.branch != @current &&
                "bg-(--surface-2) text-(--text-muted) hover:bg-(--bg) hover:text-(--text)",
              tab.leaving_at && "queue-leaving"
            ]
          }
          style={leaving_style(tab)}
        >
          <.link
            navigate={MergeWeb.mr_path(tab.branch)}
            class="flex min-w-0 items-center gap-2 py-2 pl-3"
            title={tab.branch}
          >
            <span
              :if={tab.next}
              class="shrink-0 rounded-full bg-(--info-bg) px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide text-(--info-text)"
            >
              Next
            </span>
            <span :if={tab.leaving_at} class="shrink-0 text-xs font-medium text-(--ok-text)">
              ✓ {MergeWeb.MergeRequestComponents.status_label(tab.status)}
            </span>
            <span class="truncate">{tab.title}</span>
            <span class="shrink-0 text-xs text-(--text-faint)">
              {age(tab.added_at)}
            </span>
          </.link>
          <button
            type="button"
            id={"queue-remove-#{tab.branch}"}
            phx-click="queue_remove"
            phx-value-branch={tab.branch}
            class="px-2 py-2 text-(--text-faint) opacity-60 transition hover:text-(--text) hover:opacity-100"
            aria-label={"Take #{tab.title} off the queue"}
          >
            ×
          </button>
        </div>
      </div>
    </nav>
    """
  end

  # How long it has been in the queue: 4m, 2h, 1d.
  defp age(at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  # The fade runs over the linger time; the delay puts it where it should be
  # now, so a re-render doesn't start it again.
  defp leaving_style(%{leaving_at: nil}), do: nil

  defp leaving_style(%{leaving_at: leaving_at}) do
    linger = Merge.Queue.linger_ms()
    left = max(DateTime.diff(leaving_at, DateTime.utc_now(), :millisecond), 0)
    "animation-duration: #{linger}ms; animation-delay: -#{linger - left}ms"
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
