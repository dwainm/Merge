defmodule MergeWeb.Router do
  use MergeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MergeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MergeWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/mr/*branch", MergeRequestLive
    live "/drift", DriftLive
    live "/checks/:sha", ChecksLive
  end

  # The MCP server: claude mcp add --transport http merge http://localhost:<PORT>/mcp
  forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
    server: Merge.MCP,
    request_timeout: Merge.MCP.request_timeout()

  # The CLI's API, JSON on localhost.
  scope "/api", MergeWeb do
    pipe_through :api

    get "/merge_requests", ApiController, :index
    post "/open", ApiController, :open
    post "/show", ApiController, :show
    post "/wait", ApiController, :wait
    post "/addressed", ApiController, :addressed
    post "/reply", ApiController, :reply
    post "/merged", ApiController, :merged
    post "/close", ApiController, :close
    get "/events", EventsController, :index
  end

  # Screenshots named in a merge request's body, read-only.
  scope "/", MergeWeb do
    get "/shot", ShotController, :show
  end

  # Last, so it only catches what nothing above matched.
  scope "/", MergeWeb do
    pipe_through :browser

    get "/*path", RedirectController, :home
  end
end
