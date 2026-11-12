defmodule Mix.Tasks.Merge.Serve do
  @shortdoc "Starts the Merge server"
  @moduledoc """
  Starts the server on a free port (or `--port N`), prints its localhost and
  tailnet URLs, writes the localhost one to `~/.merge/url` for the other
  commands, and keeps running.

  When another server (the systemd service, usually) already holds the tailnet
  name, this one runs on localhost only and leaves `~/.merge/url` and the
  stored merge requests to it: its own are kept in memory only.

  `MERGE_HOME=DIR` puts everything this server keeps under `DIR` instead of
  `~/.merge` (merge requests, events, the checks' checkout, the auto-push
  toggle, `url`), and stays on localhost: a test server that remembers.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          port: :integer,
          repo: :string,
          check: :string,
          check_image: :string,
          auto_push_after: :string
        ]
      )

    if port = opts[:port], do: System.put_env("PORT", Integer.to_string(port))
    # Decided before the app starts, since starting it restores the store.
    Mix.Task.run("app.config")

    case Merge.Serve.configure(opts) do
      :ok -> :ok
      {:error, _} -> Mix.raise("--auto-push-after takes a period like 20m, 90s or 1h")
    end

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")
    Enum.each(Merge.Serve.announce(), &IO.puts/1)

    unless IEx.started?(), do: Process.sleep(:infinity)
  end
end
