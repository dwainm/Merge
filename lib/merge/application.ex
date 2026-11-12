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
      # What pages read; before the merge requests, which write it.
      Merge.Board,
      {DynamicSupervisor, name: Merge.MergeRequests, strategy: :one_for_one},
      Merge.Checks,
      Merge.DevScript,
      Merge.Watcher,
      {Merge.MCP, transport: :streamable_http, request_timeout: Merge.MCP.request_timeout()},
      # Start to serve requests, typically the last entry
      MergeWeb.Endpoint
    ]

    # The fetch and the server probes, each in a worker of its own, beside the watcher.
    {before, rest} = Enum.split_while(children, &(&1 != Merge.Watcher))
    children = before ++ Merge.Background.children() ++ rest

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Merge.Supervisor]

    # The built release has no `merge serve` to tell it its settings: they
    # come from its environment, before anything starts.
    if Merge.Serve.release?(), do: Merge.Serve.configure(Merge.Serve.from_env())

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # The merge requests from before the last stop.
      Merge.MergeRequest.restore_all()
      if Merge.Serve.release?(), do: Enum.each(Merge.Serve.announce(), &IO.puts/1)
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
