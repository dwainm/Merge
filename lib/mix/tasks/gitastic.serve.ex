defmodule Mix.Tasks.Gitastic.Serve do
  @shortdoc "Starts the gitastic server"
  @moduledoc """
  Starts the server on a free port (or `--port N`), prints its localhost and
  tailnet URLs, writes the localhost one to `~/.gitastic/url` for the other
  commands, and keeps running.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [port: :integer])

    if port = opts[:port], do: System.put_env("PORT", Integer.to_string(port))
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")

    local = GitasticWeb.base_url(:local)
    File.mkdir_p!(Path.dirname(Gitastic.CLI.url_file()))
    File.write!(Gitastic.CLI.url_file(), local <> "\n")

    IO.puts("gitastic: #{local}")

    case GitasticWeb.DevTunnel.publish() do
      {:ok, url} -> IO.puts("Tailnet:  #{url}")
      :none -> :ok
    end

    unless IEx.started?(), do: Process.sleep(:infinity)
  end
end
