defmodule Merge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MergeWeb.Telemetry,
      {Phoenix.PubSub, name: Merge.PubSub},
      {Registry, keys: :unique, name: Merge.Registry},
      {DynamicSupervisor, name: Merge.MergeRequests, strategy: :one_for_one},
      Merge.Checks,
      Merge.Watcher,
      {Merge.MCP, transport: :streamable_http, request_timeout: Merge.MCP.request_timeout()},
      # Start to serve requests, typically the last entry
      MergeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Merge.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # The merge requests from before the last stop.
      Merge.MergeRequest.restore_all()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MergeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
