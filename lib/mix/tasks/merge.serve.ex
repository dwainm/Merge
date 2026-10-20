defmodule Mix.Tasks.Merge.Serve do
  @shortdoc "Starts the Merge server"
  @moduledoc """
  Starts the server on a free port (or `--port N`), prints its localhost and
  tailnet URLs, writes the localhost one to `~/.merge/url` for the other
  commands, and keeps running.

  When another server (the systemd service, usually) already holds the tailnet
  name, this one runs on localhost only and leaves `~/.merge/url` and the
  stored merge requests to it: its own are kept in memory only.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [port: :integer, repo: :string, check: :string])

    if port = opts[:port], do: System.put_env("PORT", Integer.to_string(port))
    # Decided before the app starts, since starting it restores the store.
    Mix.Task.run("app.config")

    if match?({:held, _}, MergeWeb.DevTunnel.held_by()),
      do: Application.put_env(:merge, :store_dir, nil)

    # The checks a new tip of main must pass before Push (`sh -c`, in a checkout of its own).
    if check = opts[:check], do: Application.put_env(:merge, :check_command, check)

    # The repo whose main the home page compares with GitHub.
    if repo = opts[:repo], do: Application.put_env(:merge, :repo, Path.expand(repo))

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")

    local = MergeWeb.base_url(:local)
    IO.puts("merge: #{local}")

    case MergeWeb.DevTunnel.publish() do
      {:ok, url} ->
        IO.puts("Tailnet:  #{url}")
        write_url(local)

      :none ->
        write_url(local)

      {:held, port} ->
        IO.puts("""
        The tailnet name is held by another Merge server on localhost:#{port}
        (the service: systemctl --user status merge). This one is localhost only,
        and keeps its merge requests in memory only.
        Point commands at it with: MERGE_URL=#{local} merge mr ...\
        """)
    end

    unless IEx.started?(), do: Process.sleep(:infinity)
  end

  defp write_url(local) do
    File.mkdir_p!(Path.dirname(Merge.CLI.url_file()))
    File.write!(Merge.CLI.url_file(), local <> "\n")
  end
end
