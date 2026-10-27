defmodule Merge.DevScript do
  @moduledoc """
  Runs a tree's own `bin/dev` for the server sheet, from inside the tree:
  Restart is `bin/dev stop` then `bin/dev start`, Reseed is `bin/dev reseed`,
  Turn off is `bin/dev stop`. Merge knows nothing of how a repo starts its
  server; a tree without an executable `bin/dev` gets no actions.

  One run at a time per tree. After a start it waits for the server to answer
  (an error page counts: that is the answer), after a stop for it to be gone,
  then refreshes `Merge.Servers` so the dot shows the new status.

  The runs, `%{path => run}`, are broadcast on `Merge.Servers.topic/0` as
  `{:dev_runs, runs}`. A run is `%{action, name, state, message, output, at}`:
  `state` is `:running`, `:ok` or `:failed`, `message` says what happened, and
  `output` is the last lines the commands printed.
  """

  use GenServer

  alias Merge.Servers

  @actions %{
    "restart" => {:restart, ["stop", "start"]},
    "reseed" => {:reseed, ["reseed"]},
    "off" => {:off, ["stop"]}
  }

  # How long a started server has to answer, and a stopped one to go.
  @start_wait_ms 120_000
  @stop_wait_ms 20_000
  @output_lines 20

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The tree has a `bin/dev` Merge may run."
  def script?(path) do
    case File.stat(Path.join([path, "bin", "dev"])) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @doc "The runs by tree path, the last one of each."
  def runs, do: GenServer.call(__MODULE__, :runs)

  @doc """
  Starts `action` ("restart", "reseed" or "off") in the tree at `path`, named
  `name` in the messages. `{:error, :no_script}` without `bin/dev`,
  `{:error, :busy}` while the tree's last run is still going.
  """
  def run(path, name, action) when is_map_key(@actions, action) do
    if script?(path),
      do: GenServer.call(__MODULE__, {:run, path, name, action}),
      else: {:error, :no_script}
  end

  @impl true
  def init(nil), do: {:ok, %{runs: %{}, tasks: %{}}}

  @impl true
  def handle_call(:runs, _from, state), do: {:reply, state.runs, state}

  def handle_call({:run, path, name, action}, _from, state) do
    if match?(%{state: :running}, state.runs[path]) do
      {:reply, {:error, :busy}, state}
    else
      {key, commands} = @actions[action]
      task = Task.async(fn -> perform(path, name, key, commands) end)

      run = %{action: key, name: name, state: :running, message: nil, output: [], at: now()}
      state = %{state | tasks: Map.put(state.tasks, task.ref, path)}
      {:reply, :ok, put_run(state, path, run)}
    end
  end

  @impl true
  def handle_info({ref, {result, message, output}}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {path, tasks} = Map.pop(state.tasks, ref)
    run = %{state.runs[path] | state: result, message: message, output: output, at: now()}
    Servers.refresh()
    {:noreply, put_run(%{state | tasks: tasks}, path, run)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) when is_map_key(state.tasks, ref) do
    {path, tasks} = Map.pop(state.tasks, ref)
    message = "Merge's run of bin/dev crashed: #{Exception.format_exit(reason)}"
    run = %{state.runs[path] | state: :failed, message: message, at: now()}
    {:noreply, put_run(%{state | tasks: tasks}, path, run)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp put_run(state, path, run) do
    runs = Map.put(state.runs, path, run)
    Phoenix.PubSub.broadcast(Merge.PubSub, Servers.topic(), {:dev_runs, runs})
    %{state | runs: runs}
  end

  # The commands one after another, stopping at the first that fails; then the wait.
  defp perform(path, name, action, commands) do
    {result, message, out} =
      case run_commands(path, commands, []) do
        {:ok, out} ->
          settle(path, name, action, out)

        {:failed, command, code, out} ->
          {:failed, "bin/dev #{command} failed (exit #{code}).", out}
      end

    {result, message, Enum.take(out, -@output_lines)}
  end

  defp run_commands(_path, [], out), do: {:ok, out}

  defp run_commands(path, [command | rest], out) do
    {text, code} = cmd(path, command)
    out = out ++ ["$ bin/dev #{command}" | String.split(text, "\n", trim: true)]
    if code == 0, do: run_commands(path, rest, out), else: {:failed, command, code, out}
  end

  defp settle(path, name, :off, out) do
    case wait(path, &(&1 == :off), deadline(@stop_wait_ms)) do
      :off -> {:ok, "Turned off #{name}'s server.", out}
      _ -> {:failed, "bin/dev stop ran, but #{name}'s server is still listening.", out}
    end
  end

  defp settle(path, name, action, out) do
    done = if action == :reseed, do: "Reseeded", else: "Restarted"

    case wait(path, &(&1 in [:up, :error]), deadline(@start_wait_ms)) do
      :up ->
        {:ok, "#{done} #{name}. Its server answers.", out}

      {:error, reason} ->
        {:failed, "#{done} #{name}, but its pages show an error: #{reason}", out}

      _ ->
        {:failed,
         "#{done}, but #{name}'s server isn't answering after #{div(@start_wait_ms, 60_000)} minutes. Its log says why.",
         out}
    end
  end

  # The tree's status once `done?`, or the last one read at the deadline.
  defp wait(path, done?, deadline) do
    {status, reason} = Servers.status(path)

    cond do
      done?.(status) ->
        found(status, reason)

      System.monotonic_time(:millisecond) > deadline ->
        status

      true ->
        Process.sleep(2_000)
        wait(path, done?, deadline)
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp found(:error, reason), do: {:error, reason}
  defp found(status, _), do: status

  # Under the systemd service, the command runs in a scope of its own, so a
  # server it starts outlives a restart of Merge (which kills its own cgroup).
  defp cmd(path, command) do
    {exe, args} =
      if System.get_env("INVOCATION_ID") && System.find_executable("systemd-run"),
        do: {"systemd-run", ~w(--user --scope --quiet --collect -- bin/dev #{command})},
        else: {Path.join([path, "bin", "dev"]), [command]}

    # Merge's own environment isn't the tree's: `merge serve` sets PORT, which
    # would pin the tree's server to Merge's port.
    System.cmd(exe, args,
      cd: path,
      stderr_to_stdout: true,
      env: [{"PORT", nil}, {"MIX_ENV", nil}, {"MIX_QUIET", nil}, {"MERGE_CWD", nil}]
    )
  rescue
    e -> {Exception.message(e), 127}
  end

  defp now, do: DateTime.utc_now()
end
