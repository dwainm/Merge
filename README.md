# gitastic

Review a branch against `main` on your phone and approve it, with the answer sent
to the agent waiting on it. Merge requests live in the server's memory; they are
gone when it stops.

## Run it

    mix setup
    bin/gitastic serve            # or --port N; prints the localhost and tailnet URLs

`bin/gitastic` works from any directory (link it onto your PATH). The other commands
find the server through `~/.gitastic/url`:

    gitastic mr open <branch> [--repo PATH] [--base BRANCH] [--title T] [--body B | --body-file F] [--as NAME]
    gitastic mr wait <branch>                          # blocks until a decision, prints it with the comments
    gitastic mr addressed <branch> <commit> [--note "..."]
    gitastic mr close <branch>
    gitastic mr list

The repo defaults to the current directory and the base to `origin/main` (else
`main`). An agent's name is `--as`, else `GITASTIC_AS`, else the current directory's name.

## As an MCP server

    claude mcp add --transport http gitastic http://localhost:<PORT>/mcp

Tools: `open_merge_request`, `wait_for_review` (holds up to 5 minutes, then asks
to be called again), `addressed`, `close_merge_request`, `list_merge_requests`.

## On the tailnet

With Tailscale and the Caddy dev proxy (`/etc/caddy/sites`), `serve` publishes
`https://gitastic.dev.dayofplenty.com` (`GitasticWeb.DevTunnel`).
