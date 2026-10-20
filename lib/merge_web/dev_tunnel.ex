defmodule MergeWeb.DevTunnel do
  @moduledoc """
  Publishes the running server on the tailnet as `https://merge.<domain>/`
  through the local Caddy dev proxy, the way Day of Plenty's `DopWeb.DevTunnel`
  does: it writes a Caddy site block pointing at the port the endpoint got,
  reloads Caddy, and remembers the URL for links (`MergeWeb.mr_url/1`). On a
  machine without Tailscale or the Caddy sites directory it does nothing.

  One server holds the name at a time: when the site block points at another
  port that still answers (the systemd service, usually), it is left alone.

  Configured in `config/dev.exs`:

      config :merge, MergeWeb.DevTunnel,
        host: "merge.dev.dayofplenty.com",
        caddy_sites: "/etc/caddy/sites"
  """

  require Logger

  @doc """
  Publishes the server. Returns `{:ok, url}`, `{:held, port}` when another live
  server holds the name, or `:none` when there is no tunnel here.
  """
  def publish do
    with opts when is_list(opts) <- Application.get_env(:merge, __MODULE__),
         {:ok, {_ip, port}} <- MergeWeb.Endpoint.server_info(:http),
         :ok <- tailscale_running(),
         {:ok, sites} <- caddy_sites(opts),
         file = Path.join(sites, "merge.conf"),
         :free <- holder(file, port) do
      host = Keyword.fetch!(opts, :host)
      url = "https://#{host}"

      File.write!(file, site_block(host, port))
      System.cmd("systemctl", ["--user", "reload", "caddy-dev"], stderr_to_stdout: true)
      Application.put_env(:merge, :tunnel_url, url)
      Logger.info("Tailnet: #{url} -> localhost:#{port}")
      {:ok, url}
    else
      {:held, port} -> {:held, port}
      _ -> :none
    end
  end

  @doc """
  `{:held, port}` when a live server already holds the name, before this one
  starts; else `:free`.
  """
  def held_by do
    with opts when is_list(opts) <- Application.get_env(:merge, __MODULE__) do
      holder(Path.join(Keyword.fetch!(opts, :caddy_sites), "merge.conf"), nil)
    else
      _ -> :free
    end
  end

  # The port the site block points at, when it is another server that answers.
  defp holder(file, our_port) do
    with {:ok, block} <- File.read(file),
         [_, port] <- Regex.run(~r/reverse_proxy localhost:(\d+)/, block),
         port = String.to_integer(port),
         true <- port != our_port,
         {:ok, socket} <- :gen_tcp.connect(~c"localhost", port, [], 1_000) do
      :gen_tcp.close(socket)
      {:held, port}
    else
      _ -> :free
    end
  end

  defp tailscale_running do
    with exe when is_binary(exe) <- System.find_executable("tailscale"),
         {_, 0} <- System.cmd(exe, ["status"], stderr_to_stdout: true) do
      :ok
    else
      _ -> :error
    end
  end

  defp caddy_sites(opts) do
    sites = Keyword.fetch!(opts, :caddy_sites)
    if File.dir?(sites), do: {:ok, sites}, else: :error
  end

  defp site_block(host, port) do
    """
    #{host} {
        root * /etc/caddy/error-pages

        reverse_proxy localhost:#{port} {
            header_up X-Forwarded-Proto https
        }

        handle_errors {
            @backenddown expression `{http.error.status_code} == 502 || {http.error.status_code} == 503`
            rewrite @backenddown /backend-down.html
            file_server @backenddown
        }
    }
    """
  end
end
