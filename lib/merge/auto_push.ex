defmodule Merge.AutoPush do
  @moduledoc """
  Pushes main to GitHub by itself, once it has been proven and left alone.

  When local main is ahead of origin/main, main's tip goes to GitHub (through
  `Merge.Drift.push/2`, as Push All does) once all of these hold: the toggle is
  on; the tip has not moved for the period (`merge serve --auto-push-after`,
  default 20 minutes; it starts again at every new tip, and when the toggle is
  turned on); the checks passed on that exact tip; its image build passed or
  was not needed; GitHub has nothing main lacks, and the dry run says the push
  will land. Anything else holds it, and `status/2` says what.

  It fails closed. The toggle is off until someone turns it on, and off when
  its file is missing or unreadable, or there is no store (tests, a server
  beside the service without `MERGE_HOME`). Without a check command nothing is
  proven, so nothing goes. A tip it tried once is not tried again until main
  moves on or someone pushes by hand: a failed push does not loop.

  No process of its own: `Merge.Watcher` calls `run/1` after each round and at
  the moment a push falls due, so a code reload never leaves an old one running.
  The toggle (`auto_push.term`) and the clock (`auto_push_clock.term`: the tip,
  when it was first seen, the last try) are kept beside the merge requests.
  """

  alias Merge.{Checks, Drift, Events, Git, Store}

  @default_ms 20 * 60_000
  # The user's clock: Africa/Johannesburg, UTC+2 all year (no daylight saving).
  @local_offset 2 * 3600

  def topic, do: "auto_push"

  @doc "The period main's tip must stay still, in milliseconds."
  def period_ms, do: Application.get_env(:merge, :auto_push_ms) || @default_ms

  @doc """
  The period from `merge serve --auto-push-after`: `20m`, `90s`, `1h`, or bare
  minutes. `{:ok, ms}` or `:error`.
  """
  def parse_period(text) do
    case Integer.parse(String.trim(text)) do
      {n, unit} when n > 0 and unit in ["", "m"] -> {:ok, n * 60_000}
      {n, "s"} when n > 0 -> {:ok, n * 1000}
      {n, "h"} when n > 0 -> {:ok, n * 3_600_000}
      _ -> :error
    end
  end

  @doc "The period as the page says it: 20 minutes, 1 minute, 90 seconds."
  def period_text(ms \\ period_ms()) do
    cond do
      rem(ms, 60_000) == 0 -> count(div(ms, 60_000), "minute")
      true -> count(div(ms, 1000), "second")
    end
  end

  ## The toggle

  @doc "Whether it is on. Off without a stored toggle that says on."
  def on? do
    match?(%{on: true}, toggle())
  end

  @doc "The stored toggle, `%{on, at}`, or nil."
  def toggle do
    case Store.get_named("auto_push") do
      %{on: on, at: %DateTime{}} = t when is_boolean(on) -> t
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Turns it on or off, from now. Turning it on starts the period afresh. Emits
  `auto-push-on` / `auto-push-off`. Without a store it stays off: `:error`.
  """
  def set(on, now \\ DateTime.utc_now()) when is_boolean(on) do
    if Store.dir() do
      Store.put_named("auto_push", %{on: on, at: now})

      if on,
        do: Events.emit("auto-push-on", "main", "after #{period_text()} still"),
        else: Events.emit("auto-push-off", "main")

      broadcast()
      Merge.Watcher.schedule_auto_push()
      :ok
    else
      :error
    end
  end

  ## The clock

  @doc "`%{tip, seen_at, tried}`: main's tip, when it was first seen, the last try (or nil)."
  def clock do
    case Store.get_named("auto_push_clock") do
      %{tip: _, seen_at: %DateTime{}} = c -> Map.put_new(c, :tried, nil)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Notes main's tip: a new one starts the clock now. Called by every
  `Merge.Drift.refresh/1`. A restart that lost the clock starts it again,
  which only ever pushes later.
  """
  def see_tip(tip, now \\ DateTime.utc_now())

  def see_tip(tip, now) when is_binary(tip) do
    case clock() do
      %{tip: ^tip} -> :ok
      _ -> Store.put_named("auto_push_clock", %{tip: tip, seen_at: now, tried: nil})
    end

    :ok
  end

  def see_tip(_tip, _now), do: :ok

  defp put_tried(tried) do
    with %{} = c <- clock(), do: Store.put_named("auto_push_clock", %{c | tried: tried})
  end

  @doc "When the tip falls due: the period after the later of its first sight and the toggle's turning on."
  def due_at(%{seen_at: seen}, %{at: on_at}) do
    start = if DateTime.compare(on_at, seen) == :gt, do: on_at, else: seen
    DateTime.add(start, div(period_ms(), 1000), :second)
  end

  ## Deciding

  @doc """
  What holds the push of `drift` (as `Merge.Drift.read/1` gives it, with
  `:landing`), at `now`:

    * `:off` — the toggle is off
    * `:even` — nothing ahead of GitHub
    * `{:hold, reason}` — something is wrong; it won't push this tip
    * `{:wait, reason, due}` — it will once the checks are done (`due` may be past)
    * `{:due, at}` — everything holds; it pushes at `at`
    * `:ready` — everything holds and the time is up

  `opts` give the checks (`:checks`, `:image`, `:checks_on`) and the last push
  (`:last_push`); by default they are read from the server.
  """
  def status(drift, now \\ DateTime.utc_now(), opts \\ []) do
    toggle = Keyword.get_lazy(opts, :toggle, &toggle/0)
    clock = Keyword.get_lazy(opts, :clock, &clock/0)

    cond do
      not match?(%{on: true}, toggle) ->
        :off

      not is_map(drift) or drift.ahead == [] ->
        :even

      drift.behind != [] ->
        {:hold, "GitHub has commits you don't: not pushing"}

      not match?(%{tip: tip} when tip == drift.main, clock) ->
        # Just moved: the next refresh starts its clock.
        {:wait, "main just moved", nil}

      tried_here?(clock, Keyword.get_lazy(opts, :last_push, &Drift.last_push/0)) ->
        {:hold, "push failed: waiting for a new tip or a hand push"}

      true ->
        due = due_at(clock, toggle)
        proven(drift, opts, due, now)
    end
  end

  defp proven(drift, opts, due, now) do
    checks_on = Keyword.get_lazy(opts, :checks_on, &checks_on?/0)
    checks = Keyword.get_lazy(opts, :checks, fn -> checks_on && Checks.status(drift.main) end)
    image = Keyword.get_lazy(opts, :image, fn -> checks_on && Checks.image_status(drift.main) end)

    cond do
      not checks_on ->
        {:hold, "no checks are set up: not pushing"}

      match?(%{ok: false}, checks) ->
        {:hold, "checks failed: not pushing"}

      not match?(%{ok: true, sha: sha} when sha == drift.main, checks) ->
        {:wait, "waiting for the checks", due}

      match?(%{ok: false}, image) ->
        {:hold, "image build failed: not pushing"}

      not (image in [:off, :not_needed] or match?(%{ok: true}, image)) ->
        {:wait, "waiting for the image build", due}

      drift[:landing] != :lands ->
        {:hold, landing_hold(drift[:landing])}

      DateTime.compare(now, due) == :lt ->
        {:due, due}

      true ->
        :ready
    end
  end

  defp landing_hold({:behind, _}), do: "GitHub has commits you don't: not pushing"
  defp landing_hold({:refused, _}), do: "the dry run was refused: not pushing"
  defp landing_hold(_), do: "waiting for the dry run"

  # This tip was tried, and no push by hand came after the try.
  defp tried_here?(%{tip: tip, tried: %{sha: tip, at: at}}, last_push) do
    case last_push do
      %{at: %DateTime{} = pushed_at} -> DateTime.compare(pushed_at, at) != :gt
      _ -> true
    end
  end

  defp tried_here?(_clock, _last_push), do: false

  defp checks_on? do
    match?(pid when is_pid(pid), Process.whereis(Checks)) and Checks.enabled?()
  end

  ## Pushing

  @doc """
  Pushes main's tip if it is `:ready`, read afresh: the drift, a new dry run,
  the checks of that exact sha. The sha that was judged is what goes, so a tip
  that moves meanwhile is not pushed. Returns the push's result, or the
  status that held it. Any error holds it. `opts` as for `status/3`.
  """
  def run(repo \\ Drift.repo(), now \\ DateTime.utc_now(), opts \\ []) do
    if on?() and is_binary(repo), do: try_push(repo, now, opts), else: :off
  rescue
    e -> {:hold, "auto-push error: " <> Exception.message(e)}
  end

  defp try_push(repo, now, opts) do
    drift =
      with %{} = d <- Drift.read(repo) do
        see_tip(d.main, now)
        Map.put(d, :landing, landing(d))
      end

    case status(drift, now, opts) do
      :ready -> push(repo, drift.main)
      other -> other
    end
  end

  defp landing(%{ahead: []}), do: nil
  defp landing(%{behind: [_ | _] = behind}), do: Drift.landing(behind, nil)
  defp landing(%{repo: repo}), do: Drift.landing([], Git.push_dry_run(repo, "main"))

  defp push(repo, sha) do
    # Marked tried before it goes, so a crash mid-push can't make it try again.
    put_tried(%{sha: sha, at: DateTime.utc_now(), ok: nil})
    result = Drift.push(repo, sha)
    put_tried(%{sha: sha, at: result.at, ok: result.ok})

    if result.ok do
      Events.emit(
        "auto-pushed",
        "main",
        "#{length(result.commits)} commits, origin at #{Events.short(result.origin)}"
      )
    end

    broadcast()
    result
  end

  ## The page

  @doc "The status line, in words, or nil when there is nothing to say."
  def text(:ready), do: "Pushing now"
  def text({:due, at}), do: "Pushes itself at #{clock_time(at)}"

  def text({:wait, reason, %DateTime{} = due}),
    do: "#{cap(reason)}; then pushes itself, at #{clock_time(due)} at the earliest"

  def text({:wait, reason, nil}), do: cap(reason)
  def text({:hold, reason}), do: cap(reason)
  def text(_), do: nil

  @doc "The status in a few words, for the header: the reason without the time it waits for."
  def short_text({:wait, reason, _due}), do: cap(reason)
  def short_text(status), do: text(status)

  @doc "`HH:MM` on the user's clock (Africa/Johannesburg)."
  def clock_time(%DateTime{} = at) do
    at |> DateTime.add(@local_offset) |> Calendar.strftime("%H:%M")
  end

  defp cap(text), do: String.capitalize(String.first(text)) <> String.slice(text, 1..-1//1)

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp broadcast, do: Phoenix.PubSub.broadcast(Merge.PubSub, topic(), :auto_push)
end
