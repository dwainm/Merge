defmodule Merge.Background do
  @moduledoc """
  A worker of its own for a job that waits on the network, so the watcher's
  round never does: `Merge.Fetcher` (fetches GitHub in each repo and asks it
  what it has, `Merge.Watcher.fetch/0`) and `Merge.Prober` (asks each dev
  server whether it answers, `Merge.Servers.refresh/0`). A fetch that hangs
  or a server that doesn't answer holds up that worker alone.

  The job runs in the worker when it is poked (`poke/1`, which returns at
  once), and by itself every `:every` ms when that is given. Pokes that
  arrive while it runs are that run; with `:gap` ms, one that arrives sooner
  than that after the last run started waits for the next.

  They run only where the watcher has its minute rounds (`on?/0`); without
  them (the tests) a round does these jobs itself, in order. A server that
  loaded this code while running has no such workers yet: `poke/1` starts
  them.
  """

  use GenServer

  @doc "The two workers, as children of `Merge.Supervisor`."
  def children do
    [
      Supervisor.child_spec(
        {
          __MODULE__,
          # By itself every minute, as often as the watcher's rounds.
          name: Merge.Fetcher,
          run: {Merge.Watcher, :fetch, []},
          every: Application.get_env(:merge, :watch_ms),
          gap: 5_000
        },
        id: Merge.Fetcher
      ),
      Supervisor.child_spec(
        {__MODULE__, name: Merge.Prober, run: {Merge.Servers, :refresh, []}},
        id: Merge.Prober
      )
    ]
  end

  @doc "True where the network jobs have workers of their own."
  def on?, do: Application.get_env(:merge, :watch_ms) != nil

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Starts the workers that aren't running (a server that loaded this code while running)."
  def ensure do
    # Already started by someone else at the same moment is as good.
    for spec <- children(),
        Process.whereis(spec.id) == nil,
        do: Supervisor.start_child(Merge.Supervisor, spec)

    :ok
  end

  @doc "Asks the worker `name` to run its job now. Returns at once."
  def poke(name) do
    if Process.whereis(name) == nil, do: ensure()
    GenServer.cast(name, :poke)
  end

  @impl true
  def init(opts) do
    # An interval, not a timer set after each run: a tick that is dropped
    # (one that arrives while the code is being loaded is) costs one run.
    if every = opts[:every], do: :timer.send_interval(every, :tick)
    {:ok, %{run: Keyword.fetch!(opts, :run), gap: opts[:gap] || 0, last: nil}}
  end

  @impl true
  def handle_cast(:poke, state), do: {:noreply, run(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, run(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  defp run(state) do
    now = System.monotonic_time(:millisecond)

    if state.last == nil or now - state.last >= state.gap do
      {module, function, args} = state.run

      try do
        apply(module, function, args)
      catch
        kind, reason ->
          require Logger

          Logger.warning(
            "#{inspect(module)}.#{function} failed: #{Exception.format(kind, reason)}"
          )
      end

      drop_asked()
      %{state | last: now}
    else
      state
    end
  end

  # Asked again while it ran: that run was this one.
  defp drop_asked do
    receive do
      {:"$gen_cast", :poke} -> drop_asked()
      :tick -> drop_asked()
    after
      0 -> :ok
    end
  end
end
