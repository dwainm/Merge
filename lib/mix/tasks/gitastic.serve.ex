defmodule Mix.Tasks.Gitastic.Serve do
  @shortdoc "Starts the gitastic server"
  @moduledoc """
  Starts the server on a free port (or `--port N`), prints its localhost and
  tailnet URLs, writes the localhost one to `~/.gitastic/url` for the other
  commands, and keeps running.

  When another server (the systemd service, usually) already holds the tailnet
  name, this one runs on localhost only and leaves `~/.gitastic/url` to it.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [port: :integer])

    if port = opts[:port], do: System.put_env("PORT", Integer.to_string(port))
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")

    local = GitasticWeb.base_url(:local)
    IO.puts("gitastic: #{local}")

    case GitasticWeb.DevTunnel.publish() do
      {:ok, url} ->
        IO.puts("Tailnet:  #{url}")
        write_url(local)

      :none ->
        write_url(local)

      {:held, port} ->
        IO.puts("""
        The tailnet name is held by another gitastic server on localhost:#{port}
        (the service: systemctl --user status gitastic). This one is localhost only.
        Point commands at it with: GITASTIC_URL=#{local} gitastic mr ...\
        """)
    end

    unless IEx.started?(), do: Process.sleep(:infinity)
  end

  defp write_url(local) do
    File.mkdir_p!(Path.dirname(Gitastic.CLI.url_file()))
    File.write!(Gitastic.CLI.url_file(), local <> "\n")
  end
end
