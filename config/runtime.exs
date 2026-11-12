import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/merge start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :merge, MergeWeb.Endpoint, server: true
end

config :merge, MergeWeb.Endpoint,
  # Port 0 asks the OS for a free port; `merge serve --port N` sets PORT.
  http: [port: String.to_integer(System.get_env("PORT", "0"))]

# How often the watcher fetches origin and checks main and the merges; off in tests.
config :merge, :watch_ms, if(config_env() != :test, do: 60_000)

# Where each merge request is kept on disk (Merge.Store). Tests keep nothing,
# and neither does an ad-hoc `merge serve` beside the main one (MERGE_STORE=off).
config :merge,
       :store_dir,
       if(config_env() != :test and System.get_env("MERGE_STORE") != "off",
         do: Path.join(System.user_home!(), ".merge/merge_requests")
       )

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :merge, MergeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/merge_web/router\.ex$"E,
        ~r"lib/merge_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The built release the service runs (`bin/merge deploy`). It listens on
  # localhost only, like the development server: there is no sign-in, and the
  # tailnet is the only way in from a phone.
  #
  # The key that signs sessions is kept beside what the server keeps
  # (`~/.merge/secret_key_base`, or under MERGE_HOME), made on the first start.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        home =
          case System.get_env("MERGE_HOME") do
            home when home not in [nil, ""] -> Path.expand(home)
            _ -> Path.join(System.user_home!(), ".merge")
          end

        file = Path.join(home, "secret_key_base")

        case File.read(file) do
          {:ok, key} when byte_size(key) >= 64 ->
            String.trim(key)

          _ ->
            key = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
            File.mkdir_p!(home)
            File.write!(file, key)
            File.chmod!(file, 0o600)
            key
        end
      )

  config :merge, MergeWeb.Endpoint,
    # A stop doesn't wait for connections to end by themselves: an agent's
    # wait is held open for 50 seconds and asks again when it is cut, and a
    # page connects again. A second each, so a restart is a few seconds.
    http: [ip: {127, 0, 0, 1}, thousand_island_options: [shutdown_timeout: 1_000]],
    drainer: [shutdown: 1_000],
    secret_key_base: secret_key_base,
    # The name it is reached by is Caddy's, on the tailnet, as in development.
    check_origin: false,
    server: true
end
