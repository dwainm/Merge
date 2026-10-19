defmodule Gitastic.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GitasticWeb.Telemetry,
      {Phoenix.PubSub, name: Gitastic.PubSub},
      {Registry, keys: :unique, name: Gitastic.Registry},
      {DynamicSupervisor, name: Gitastic.MergeRequests, strategy: :one_for_one},
      Gitastic.Watcher,
      {Gitastic.MCP,
       transport: :streamable_http, request_timeout: Gitastic.MCP.request_timeout()},
      # Start to serve requests, typically the last entry
      GitasticWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Gitastic.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # The merge requests from before the last stop.
      Gitastic.MergeRequest.restore_all()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GitasticWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
