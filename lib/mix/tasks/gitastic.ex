defmodule Mix.Tasks.Gitastic do
  @shortdoc "The gitastic command (mr open, wait, addressed, close, list)"
  @moduledoc """
  Runs a `gitastic mr ...` command against a running server. `bin/gitastic`
  calls this; `gitastic serve` goes to `Mix.Tasks.Gitastic.Serve`.

  #{Gitastic.CLI.usage()}
  """

  use Mix.Task

  @impl true
  def run(["serve" | args]), do: Mix.Task.run("gitastic.serve", args)

  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Gitastic.CLI.run(argv) do
      {:error, message} ->
        IO.puts(:stderr, String.trim_trailing(message))
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end
end
