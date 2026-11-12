defmodule Merge.Serve do
  @moduledoc """
  What a server is told when it starts, and what it says once it is up: the
  same for `merge serve` (`Mix.Tasks.Merge.Serve`, the development server) and
  for the built release the service runs (`bin/merge deploy`), which has no
  Mix and takes its settings from the environment (`from_env/0`).

  `configure/1` goes before the app starts, since starting it restores the
  store; `announce/0` after.
  """

  @doc """
  The settings of a release, from its environment: `MERGE_REPO`, `MERGE_CHECK`,
  `MERGE_CHECK_IMAGE`, `MERGE_AUTO_PUSH_AFTER`. The port is `PORT`
  (`config/runtime.exs`).
  """
  def from_env do
    for {key, name} <- [
          repo: "MERGE_REPO",
          check: "MERGE_CHECK",
          check_image: "MERGE_CHECK_IMAGE",
          auto_push_after: "MERGE_AUTO_PUSH_AFTER"
        ],
        value = System.get_env(name),
        value not in [nil, ""],
        do: {key, value}
  end

  @doc "True in the built release (it has no Mix)."
  def release?, do: System.get_env("RELEASE_NAME") not in [nil, ""]

  @doc """
  Applies `opts` (`:repo`, `:check`, `:check_image`, `:auto_push_after`) and
  decides where this server keeps things. Answers `:ok`, or `{:error, message}`
  for a period that can't be read.
  """
  def configure(opts) do
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

    # The checks a new tip of main must pass before Push (`sh -c`, in a checkout of its own).
    if check = opts[:check], do: Application.put_env(:merge, :check_command, check)

    # GitHub's image build, after the first and only when the tip touches what goes into the image.
    if image = opts[:check_image], do: Application.put_env(:merge, :check_image_command, image)

    # The repo whose main the home page compares with GitHub.
    if repo = opts[:repo], do: Application.put_env(:merge, :repo, Path.expand(repo))

    # How long main's tip stays still before Auto Push sends it (when it is on).
    case opts[:auto_push_after] do
      nil ->
        :ok

      text ->
        case Merge.AutoPush.parse_period(text) do
          {:ok, ms} -> Application.put_env(:merge, :auto_push_ms, ms)
          :error -> {:error, "the Auto Push period takes a period like 20m, 90s or 1h"}
        end
    end
  end

  @doc """
  Once the server is up: takes the tailnet name unless it has a home of its
  own or another server holds it, writes the localhost URL where the commands
  look for it, and answers the lines to print.
  """
  def announce do
    local = MergeWeb.base_url(:local)

    # A server with a home of its own is a test server: it never takes the tailnet name.
    tunnel = if Merge.CLI.home?(), do: :none, else: MergeWeb.DevTunnel.publish()

    case tunnel do
      {:ok, url} ->
        write_url(local)
        ["merge: #{local}", "Tailnet:  #{url}"]

      :none ->
        write_url(local)
        ["merge: #{local}"]

      {:held, port} ->
        [
          "merge: #{local}",
          """
          The tailnet name is held by another Merge server on localhost:#{port}
          (the service: systemctl --user status merge). This one is localhost only,
          and keeps its merge requests in memory only.
          Point commands at it with: MERGE_URL=#{local} merge mr ...\
          """
        ]
    end
  end

  defp write_url(local) do
    File.mkdir_p!(Path.dirname(Merge.CLI.url_file()))
    File.write!(Merge.CLI.url_file(), local <> "\n")
  end
end
