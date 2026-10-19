defmodule GitasticWeb.DevTunnel do
  @moduledoc """
  Publishes the running server on the tailnet as `https://gitastic.<domain>/`
  through the local Caddy dev proxy, the way Day of Plenty's `DopWeb.DevTunnel`
  does: it writes a Caddy site block pointing at the port the endpoint got,
  reloads Caddy, and remembers the URL for links (`GitasticWeb.mr_url/1`). On a
  machine without Tailscale or the Caddy sites directory it does nothing.

  Configured in `config/dev.exs`:

      config :gitastic, GitasticWeb.DevTunnel,
        host: "gitastic.dev.dayofplenty.com",
        caddy_sites: "/etc/caddy/sites"
  """

  require Logger

  @doc "Publishes the server. Returns `{:ok, url}`, or `:none` when there is no tunnel here."
  def publish do
    with opts when is_list(opts) <- Application.get_env(:gitastic, __MODULE__),
         {:ok, {_ip, port}} <- GitasticWeb.Endpoint.server_info(:http),
         :ok <- tailscale_running(),
         {:ok, sites} <- caddy_sites(opts) do
      host = Keyword.fetch!(opts, :host)
      url = "https://#{host}"

      File.write!(Path.join(sites, "gitastic.conf"), site_block(host, port))
      System.cmd("systemctl", ["--user", "reload", "caddy-dev"], stderr_to_stdout: true)
      Application.put_env(:gitastic, :tunnel_url, url)
      Logger.info("Tailnet: #{url} -> localhost:#{port}")
      {:ok, url}
    else
      _ -> :none
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
