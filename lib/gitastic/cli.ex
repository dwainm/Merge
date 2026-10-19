defmodule Gitastic.CLI do
  @moduledoc """
  The `gitastic` command. `serve` runs the server (see `Mix.Tasks.Gitastic.Serve`);
  every `mr` command talks to a running server over HTTP on localhost.

  The server writes its URL to `~/.gitastic/url`; `GITASTIC_URL` overrides it.
  Paths are relative to `GITASTIC_CWD` (the directory `bin/gitastic` was run
  from). The agent's name is `--as`, else `GITASTIC_AS`, else that directory's name.
  """

  @usage """
  gitastic serve [--port N]
  gitastic mr open <branch> [--repo PATH] [--title T] [--body B | --body-file F] [--as NAME]
  gitastic mr wait <branch> [--as NAME]
  gitastic mr addressed <branch> <commit> [--note "..."] [--as NAME]
  gitastic mr close <branch>
  gitastic mr list
  """

  @switches [
    repo: :string,
    title: :string,
    body: :string,
    body_file: :string,
    as: :string,
    note: :string,
    port: :integer
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

  defp command(["mr", "close", branch], _opts) do
    with {:ok, _} <- post("/api/close", %{branch: branch}), do: IO.puts("Closed #{branch}.")
  end

  defp command(["mr", "list"], _opts) do
    with {:ok, %{"merge_requests" => mrs}} <- request(:get, "/api/merge_requests", nil) do
      if mrs == [], do: IO.puts("No open merge requests.")

      for mr <- mrs do
        IO.puts("#{mr["branch"]}  #{mr["status"]}  #{mr["title"]}  #{mr["url"]}")
      end

      :ok
    end
  end

  defp command(_args, _opts), do: {:error, @usage}

  # Holds a request open on the server until there is news, and asks again
  # each time the server's hold runs out.
  defp wait(branch, as) do
    case post("/api/wait", %{branch: branch, as: as}) do
      {:ok, %{"status" => "waiting"}} -> wait(branch, as)
      {:ok, %{"text" => text}} -> IO.write(text)
      {:error, _} = error -> error
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

  defp post(path, body), do: request(:post, path, body)

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
        {:ok, %{status: status}} -> {:error, "The server answered #{status}."}
        {:error, _} -> {:error, "No gitastic server at #{base}. Start one with: gitastic serve"}
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
