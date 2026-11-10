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

    home = System.get_env("MERGE_HOME")

    cond do
      # Everything it keeps in a home of its own, far from the service's ~/.merge.
      home not in [nil, ""] ->
        home = Path.expand(home)
        Application.put_env(:merge, :store_dir, Path.join(home, "merge_requests"))
        Application.put_env(:merge, :checks_dir, Path.join(home, "checks"))

      # Beside the service: its own checkouts for the checks, so neither moves the other's.
      match?({:held, _}, MergeWeb.DevTunnel.held_by()) ->
        Application.put_env(:merge, :store_dir, nil)
        checks = Path.join([System.user_home!(), ".merge", "checks-#{System.get_env("PORT")}"])
        Application.put_env(:merge, :checks_dir, checks)

      true ->
        :ok
    end

    # How long main's tip stays still before Auto Push sends it (when it is on).
    with after_text when is_binary(after_text) <- opts[:auto_push_after] do
      case Merge.AutoPush.parse_period(after_text) do
        {:ok, ms} -> Application.put_env(:merge, :auto_push_ms, ms)
        :error -> Mix.raise("--auto-push-after takes a period like 20m, 90s or 1h")
      end
    end

    # The checks a new tip of main must pass before Push (`sh -c`, in a checkout of its own).
    if check = opts[:check], do: Application.put_env(:merge, :check_command, check)

    # GitHub's image build, after the first and only when the tip touches what goes into the image.
    if image = opts[:check_image], do: Application.put_env(:merge, :check_image_command, image)

    # The repo whose main the home page compares with GitHub.
    if repo = opts[:repo], do: Application.put_env(:merge, :repo, Path.expand(repo))

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")

    local = MergeWeb.base_url(:local)
    IO.puts("merge: #{local}")

    # A server with a home of its own is a test server: it never takes the tailnet name.
    tunnel = if Merge.CLI.home?(), do: :none, else: MergeWeb.DevTunnel.publish()

    case tunnel do
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
