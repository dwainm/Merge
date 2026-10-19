defmodule GitasticWeb.Router do
  use GitasticWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GitasticWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GitasticWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/mr/*branch", MergeRequestLive
  end

  # The MCP server: claude mcp add --transport http gitastic http://localhost:<PORT>/mcp
  forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
    server: Gitastic.MCP,
    request_timeout: Gitastic.MCP.request_timeout()

  # The CLI's API, JSON on localhost.
  scope "/api", GitasticWeb do
    pipe_through :api

    get "/merge_requests", ApiController, :index
    post "/open", ApiController, :open
    post "/show", ApiController, :show
    post "/wait", ApiController, :wait
    post "/addressed", ApiController, :addressed
    post "/close", ApiController, :close
  end
end
