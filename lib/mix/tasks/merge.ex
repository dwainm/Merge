defmodule Mix.Tasks.Merge do
  @shortdoc "The merge command (mr open, wait, addressed, close, list)"
  @moduledoc """
  Runs a `merge mr ...` command against a running server. `bin/merge`
  calls this; `merge serve` goes to `Mix.Tasks.Merge.Serve`.

  #{Merge.CLI.usage()}
  """

  use Mix.Task

  @impl true
  def run(["serve" | args]), do: Mix.Task.run("merge.serve", args)

  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Merge.CLI.run(argv) do
      {:error, message} ->
        IO.puts(:stderr, String.trim_trailing(message))
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end
end
