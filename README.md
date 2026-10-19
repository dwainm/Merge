# gitastic

Review a branch against `main` on your phone, comment on any line, approve or reject it.
The agent that opened the merge request is told the outcome, with every comment, on the command line.
No GitHub and no database: each merge request is a process, gone when the server stops.

## Commands

`bin/gitastic` works from any directory; link it onto your PATH as `gitastic`.

    gitastic serve [--port N]
        gitastic serve                     # prints http://localhost:<PORT> and https://gitastic.dev.dayofplenty.com

    gitastic mr open <branch> [--repo PATH] [--base BRANCH] [--title T] [--body B | --body-file F] [--as NAME]
        cd /root/projects/dayofplenty && gitastic mr open checkin --title "Coffee shop check-in"

    gitastic mr wait <branch> [--as NAME]
        gitastic mr wait checkin           # blocks until Approve or Reject, prints it with every comment

    gitastic mr addressed <branch> <commit> [--note "..."] [--as NAME]
        gitastic mr addressed checkin HEAD --note "Kept hello, added the test"

    gitastic mr merged <branch> [--commit SHA]
        gitastic mr merged checkin         # after merging into main; finds the merge commit itself

    gitastic mr close <branch>
        gitastic mr close checkin

    gitastic mr list
        gitastic mr list                   # checkin  open  Coffee shop check-in  (waiting: checkin)  <url>

The commands find the server through `~/.gitastic/url` (`GITASTIC_URL` overrides it).

## main against GitHub

The home page shows where the repo's local `main` stands against `origin/main`
(`serve --repo PATH`, else the first merge request's repo): one quiet line when
they match, else the commits on either side, a diff page, and **Push** or **Pull**.
A push is checked by fetching again; a success shows for a few seconds, a failure
stays until the next push. Every
minute the server fetches, refreshes this, and marks merge requests whose branch
is on main as "Merged", then "On origin" once origin/main has it. The badges: Review
(also when sent back for work), Approved, Merged, On origin, Closed.

## Checks before Push

`serve --check CMD` runs `CMD` (with `sh -c`) on every new tip of local `main`, in a
checkout of its own (a detached worktree under `~/.gitastic/checks/`), one run at a
time; a tip that's already superseded is skipped. For Day of Plenty:

    --check 'MIX_ENV=test MIX_TEST_PARTITION=_gitastic_checks; export MIX_ENV MIX_TEST_PARTITION;
             mix deps.get && mix compile --warnings-as-errors && mix check'

The home card shows "Checks passed / running / failed on <sha>" (with the failing
output), `/checks/<sha>` has the whole log, and a merged merge request shows
"main at <sha>: checks passed". **Push** is enabled only when main's tip passed;
**Push anyway** pushes regardless, after its own confirmation. Results are kept
per commit on disk.

The flow for a coordinator: merge into local main (all at once when there are
several), wait for "Checks passed" on the tip, then Push from the home page.

## MCP

    claude mcp add --transport http gitastic http://localhost:4747/mcp

Tools: `open_merge_request`, `wait_for_review`, `addressed`, `close_merge_request`, `list_merge_requests`.
Use the service's port (4747), or the one `gitastic serve` printed.

## The service

    systemctl --user enable --now /root/projects/gitastic/systemd/gitastic.service

It runs `gitastic serve --port 4747`, restarts itself, and holds the tailnet name. Any
`gitastic serve` started while it runs stays on localhost and says so. After pulling
a change that adds a library: `systemctl --user restart gitastic` (the dev code
reloader picks up code changes, but not new libraries).

## Decisions

- **The CLI is a shell wrapper around two Mix tasks** (`gitastic.serve`, `gitastic`), not an escript:
  an escript can't serve Phoenix's static assets. A client command costs about a second of Mix
  startup. Client commands run with `MIX_QUIET=1` so no compile message reaches an agent.
- **An agent's name** is `--as`, else `GITASTIC_AS`, else the current directory's name (the
  worktree name, which is the stream's name).
- **Opening an open branch again** registers the second agent on the same merge request.
- **`mr wait` returns on every comment and every decision.** Each agent (by name) has a cursor;
  a wait answers at once with what that agent hasn't heard, else blocks until there is some, so
  nothing said while an agent re-arms is missed. It also returns CONFLICTS when the branch stops
  merging cleanly into main (checked every minute, and whenever main moves), naming the files. Run it again after each answer to keep listening.
  It long-polls (50s holds) and rides out a server restart.
- **Merge requests are kept on disk** under `~/.gitastic/merge_requests/`, one term file each,
  written on every change and loaded on start.
- **The review goes in rounds.** A comment belongs to the round it was written in; a decision closes
  the round; `addressed` answers it with a commit and a note, recomputes the diff and opens the next
  round. The wait output lists this round's comments, then the earlier ones with their notes.
- **Reject needs a note or a comment in its round.** Approve doesn't.
- **`addressed` takes any commit reachable from the branch.**
- **The base is `origin/main` when the repo has it, else `main`**; `--base` reviews a stacked
  branch against its parent.
- **Diffs** are `git diff base...branch`, cached in the merge request's process and recomputed on
  `addressed`. A commit's diff is against its first parent. "Since your review" is the diff from
  the head that was reviewed to the current head; commits after it are marked new.
- **Line comments** are tied to the view they were written on (the whole branch, or one commit).
- **Syntax colours** come from Makeup; each side of a hunk is lexed as one text so strings and
  heredocs that span lines keep their colour.
- **MCP** uses `anubis_mcp` over Streamable HTTP at `/mcp`. It runs one request at a time per
  session, so `wait_for_review` holds for up to 5 minutes, then answers "Still waiting, call again".
- **No sign-in.** The server listens on localhost; the tailnet is the only way in from a phone.
