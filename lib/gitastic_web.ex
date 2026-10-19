defmodule GitasticWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use GitasticWeb, :controller
      use GitasticWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc "The path of a merge request's page. Branch names keep their slashes."
  def mr_path(branch), do: "/mr/" <> branch

  @doc """
  The full URL of a merge request's page: the tailnet one when the server is
  published there (`GitasticWeb.DevTunnel`), else localhost. `:local` is always localhost.
  """
  def mr_url(branch, which \\ :public), do: base_url(which) <> mr_path(branch)

  def base_url(:public), do: Application.get_env(:gitastic, :tunnel_url) || base_url(:local)

  def base_url(:local) do
    case GitasticWeb.Endpoint.server_info(:http) do
      {:ok, {_ip, port}} -> "http://localhost:#{port}"
      _ -> GitasticWeb.Endpoint.url()
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import GitasticWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias GitasticWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: GitasticWeb.Endpoint,
        router: GitasticWeb.Router,
        statics: GitasticWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
