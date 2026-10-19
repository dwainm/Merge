defmodule Gitastic.CLI do
  @moduledoc """
  The `gitastic` command. `serve` runs the server (see `Mix.Tasks.Gitastic.Serve`);
  every `mr` command talks to a running server over HTTP on localhost.

  The server writes its URL to `~/.gitastic/url`; `GITASTIC_URL` overrides it.
  Paths are relative to `GITASTIC_CWD` (the directory `bin/gitastic` was run
  from). The agent's name is `--as`, else `GITASTIC_AS`, else that directory's name.
  """

  @usage """
  gitastic serve [--port N] [--repo PATH] [--check CMD]
  gitastic mr open <branch> [--repo PATH] [--base BRANCH] [--title T] [--body B | --body-file F] [--as NAME]
  gitastic mr wait <branch> [--as NAME]      returns on each comment or decision; run it again to keep listening
  gitastic mr addressed <branch> <commit> [--note "..."] [--as NAME]
  gitastic mr merged <branch> [--commit SHA]  marks it merged (found on main when no --commit)
  gitastic mr close <branch>
  gitastic mr list
  gitastic mr watch [--since TIME]           one line per event on any merge request or main, until stopped;
                                             TIME is 2026-10-19T14:00:00Z or an age like 30m, 2h, 1d
  """

  @switches [
    repo: :string,
    base: :string,
    title: :string,
    body: :string,
    body_file: :string,
    as: :string,
    note: :string,
    port: :integer,
    commit: :string,
    since: :string
  ]

  def usage, do: @usage

  def url_file, do: Path.join([System.user_home!(), ".gitastic", "url"])

  def cwd, do: System.get_env("GITASTIC_CWD") || File.cwd!()

  @doc "Runs an `mr` command. Returns `:ok` or `{:error, message}`."
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      {:error, "Unknown option #{invalid |> hd() |> elem(0)}\n\n" <> @usage}
    else
      command(args, opts)
    end
  end

  defp command(["mr", "open", branch], opts) do
    with {:ok, body} <- body(opts),
         {:ok, %{"merge_request" => mr, "result" => result}} <-
           post("/api/open", %{
             branch: branch,
             repo: Path.expand(opts[:repo] || ".", cwd()),
             base: opts[:base],
             title: opts[:title],
             body: body,
             as: agent(opts)
           }) do
      verb = if result == "existing", do: "Already open", else: "Opened"

      IO.puts("""
      #{verb}: #{mr["title"]} (#{mr["branch"]} → #{mr["base"]}, #{mr["commits"]} commits, #{mr["files"]} files)
      #{mr["url"]}
      Wait for the review with: gitastic mr wait #{mr["branch"]}\
      """)
    end
  end

  defp command(["mr", "wait", branch], opts), do: wait(branch, agent(opts))

  defp command(["mr", "addressed", branch, commit], opts) do
    with {:ok, %{"addressed" => a, "url" => url}} <-
           post("/api/addressed", %{
             branch: branch,
             commit: commit,
             note: opts[:note],
             as: agent(opts)
           }) do
      IO.puts("Addressed in #{a["short"]}. Ready for review again: #{url}")
      IO.puts("Wait for the next decision with: gitastic mr wait #{branch}")
    end
  end

  defp command(["mr", "merged", branch], opts) do
    with {:ok, %{"merged" => m, "url" => url}} <-
           post("/api/merged", %{branch: branch, commit: opts[:commit]}) do
      where = if m["pushed"], do: "on origin", else: "not pushed yet"
      IO.puts("Merged #{branch} in #{m["short"]}: #{m["subject"]} (#{where})\n#{url}")
    end
  end

  defp command(["mr", "close", branch], _opts) do
    with {:ok, %{"status" => status}} <- post("/api/close", %{branch: branch}) do
      IO.puts(
        "#{String.capitalize(state(status))} #{branch}. It stays on the home page, read-only."
      )
    end
  end

  defp command(["mr", "list"], _opts) do
    with {:ok, %{"merge_requests" => mrs}} <- get("/api/merge_requests") do
      if mrs == [], do: IO.puts("No open merge requests.")

      for mr <- mrs do
        waiting =
          if mr["waiting"] == [],
            do: "nobody waiting",
            else: "waiting: " <> Enum.join(mr["waiting"], ", ")

        merged =
          case mr["merged"] do
            %{"short" => short, "pushed" => true} -> " on origin in #{short}"
            %{"short" => short} -> " in #{short}"
            _ -> ""
          end

        flags =
          [
            mr["merges"] == "conflicts" && "CONFLICTS (#{Enum.join(mr["conflicts"], ", ")})",
            mr["branch_state"] == "rewritten" && "REWRITTEN",
            mr["branch_state"] == "gone" && "BRANCH GONE"
          ]
          |> Enum.filter(& &1)
          |> Enum.map_join(&("  " <> &1))

        IO.puts(
          "#{mr["branch"]}  #{state(mr["status"])}#{merged}#{flags}  #{mr["title"]}  (#{waiting})  #{mr["url"]}"
        )
      end

      :ok
    end
  end

  defp command(["mr", "watch"], opts) do
    with {:ok, since} <- since(opts[:since]) do
      watch(since || DateTime.utc_now(), false)
    end
  end

  defp command(_args, _opts), do: {:error, @usage}

  # Streams the event lines, printing each as it comes. When the stream ends
  # (a restart, a dropped connection) it connects again and asks for what
  # came after the last line it printed, so nothing is missed or repeated.
  defp watch(since, retrying?) do
    Process.put(:watch, %{buffer: "", last: since})
    # Read each time: a restarted server may be on another port.
    base = with {:ok, base} <- server_url(), do: base, else: (_ -> nil)

    result =
      base &&
        Req.get(base <> "/api/events",
          params: [since: DateTime.to_iso8601(since)],
          receive_timeout: 60_000,
          retry: false,
          into: fn {:data, data}, acc ->
            watch_data(data)
            {:cont, acc}
          end
        )

    last = Process.get(:watch).last

    retrying? =
      case result do
        {:ok, %{status: 200}} ->
          false

        {:ok, %{status: status}} ->
          IO.puts(:stderr, "The server answered #{status}. Trying again until it is back.")
          true

        _ ->
          unless retrying?,
            do: IO.puts(:stderr, "No gitastic server. Trying again until it is back.")

          true
      end

    Process.sleep(3_000)
    watch(last, retrying?)
  end

  defp watch_data(data) do
    %{buffer: buffer, last: last} = Process.get(:watch)
    [rest | lines] = String.split(buffer <> data, "\n") |> Enum.reverse()

    last =
      lines
      |> Enum.reverse()
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(last, fn line, last ->
        case Gitastic.Events.time(line) do
          nil ->
            last

          time ->
            [_stamp, rest] = String.split(line, " ", parts: 2)
            IO.puts("#{time |> DateTime.truncate(:second) |> DateTime.to_iso8601()} #{rest}")
            time
        end
      end)

    Process.put(:watch, %{buffer: rest, last: last})
  end

  defp since(nil), do: {:ok, nil}

  defp since(text) do
    case Regex.run(~r/^(\d+)([smhd])$/, text) do
      [_, n, unit] ->
        seconds = String.to_integer(n) * %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}[unit]
        {:ok, DateTime.add(DateTime.utc_now(), -seconds)}

      nil ->
        case DateTime.from_iso8601(text) do
          {:ok, time, _} ->
            {:ok, time}

          {:error, _} ->
            {:error, "--since takes a time like 2026-10-19T14:00:00Z, or an age like 30m."}
        end
    end
  end

  defp state("open"), do: "review"
  defp state("needs_work"), do: "review"
  defp state("approved"), do: "approved"
  defp state("merged"), do: "merged"
  defp state("closed"), do: "closed"
  defp state(other), do: other

  # Holds a request open on the server until there is news, and asks again
  # each time the server's hold runs out. A server that is restarting (refused,
  # or answering 5xx) is asked again every few seconds: merge requests survive it.
  defp wait(branch, as, retrying? \\ false) do
    case post("/api/wait", %{branch: branch, as: as}) do
      {:ok, %{"status" => "waiting"}} ->
        wait(branch, as)

      {:ok, %{"text" => text}} ->
        IO.write(text)

      {:retry, message} ->
        unless retrying?, do: IO.puts(:stderr, message <> " Trying again until it is back.")
        Process.sleep(3_000)
        wait(branch, as, true)

      {:error, _} = error ->
        error
    end
  end

  defp body(opts) do
    case opts[:body_file] do
      nil ->
        {:ok, opts[:body]}

      file ->
        case File.read(Path.expand(file, cwd())) do
          {:ok, body} -> {:ok, body}
          {:error, reason} -> {:error, "Can't read #{file}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp agent(opts), do: opts[:as] || System.get_env("GITASTIC_AS") || Path.basename(cwd())

  defp post("/api/wait" = path, body), do: request(:post, path, body)

  defp post(path, body) do
    case request(:post, path, body) do
      {:retry, message} -> {:error, message <> " Is it running? Start one with: gitastic serve"}
      other -> other
    end
  end

  defp get(path) do
    case request(:get, path, nil) do
      {:retry, message} -> {:error, message <> " Is it running? Start one with: gitastic serve"}
      other -> other
    end
  end

  defp request(method, path, body) do
    with {:ok, base} <- server_url() do
      case Req.request(
             method: method,
             url: base <> path,
             json: body,
             receive_timeout: 120_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{body: %{"error" => message}}} -> {:error, message}
        {:ok, %{status: status}} when status >= 500 -> {:retry, "The server answered #{status}."}
        {:ok, %{status: status}} -> {:error, "The server answered #{status}."}
        {:error, _} -> {:retry, "No gitastic server at #{base}."}
      end
    end
  end

  defp server_url do
    case System.get_env("GITASTIC_URL") do
      url when url not in [nil, ""] ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        case File.read(url_file()) do
          {:ok, url} -> {:ok, String.trim(url)}
          {:error, _} -> {:error, "No gitastic server is running. Start one with: gitastic serve"}
        end
    end
  end
end
