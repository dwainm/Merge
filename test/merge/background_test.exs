defmodule Merge.BackgroundTest do
  use ExUnit.Case, async: true

  alias Merge.Background

  # The job tells the test it started, then waits to be let go.
  def job(test) do
    send(test, {:started, self()})

    receive do
      :go -> :ok
    end
  end

  def quick(test), do: send(test, :ran)

  defp worker(opts) do
    name = :"background_#{System.unique_integer([:positive])}"
    start_supervised!({Background, [name: name] ++ opts}, id: name)
    name
  end

  test "a poke returns at once; the job runs in the worker" do
    name = worker(run: {__MODULE__, :job, [self()]})
    assert :ok = Background.poke(name)
    assert_receive {:started, pid}
    assert pid == Process.whereis(name)
    send(pid, :go)
  end

  test "pokes that arrive while it runs are that run" do
    name = worker(run: {__MODULE__, :job, [self()]})
    Background.poke(name)
    assert_receive {:started, pid}
    for _ <- 1..5, do: Background.poke(name)
    send(pid, :go)
    _ = :sys.get_state(name)
    refute_received {:started, _}

    # The next one runs.
    Background.poke(name)
    assert_receive {:started, ^pid}
    send(pid, :go)
  end

  test "with a gap, a poke too soon after the last run waits for the next" do
    name = worker(run: {__MODULE__, :quick, [self()]}, gap: 60_000)
    Background.poke(name)
    assert_receive :ran
    Background.poke(name)
    _ = :sys.get_state(name)
    refute_received :ran
  end

  test "it runs by itself at its interval, and a job that fails doesn't stop it" do
    name = worker(run: {__MODULE__, :quick, [self()]}, every: 20)
    assert_receive :ran
    assert_receive :ran

    failing = worker(run: {Kernel, :exit, [:boom]}, every: 20)
    pid = Process.whereis(failing)
    _ = :sys.get_state(failing)
    assert Process.whereis(failing) == pid
    assert Process.whereis(name)
  end
end
