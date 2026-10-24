# deploy

Push-to-deploy for a `~/deploy` layout, POSIX sh, installs nothing. `deploy.sh`
(setup + env vars) drives `post-receive`, the hook; one copy lives on the host
at `~/deploy/post-receive`, symlinked from every repo's `hooks/post-receive`.

## New app

```sh
./deploy.sh init eli@sg1 framer                                    # dirs, repo, hook
./deploy.sh env set eli@sg1 framer DATABASE_URL=postgresql://...   # secrets
git remote add deploy eli@sg1:deploy/repos/framer
git push deploy master
```

`TINYDEPLOY_HOST` stands in for HOST on every command, so it can be left out:

```sh
export TINYDEPLOY_HOST=eli@sg1
./deploy.sh init framer
./deploy.sh env set framer DATABASE_URL=postgresql://...
```

A HOST passed on the command line still wins. `env set|rm` and `conf set|rm`
take a variable number of arguments, so a HOST given to those must be written
`user@host` (the ssh form) to be told apart from APP; the other commands take
it positionally whenever it is there.

## Env vars

`env import` reads `.env` files: comments and blank lines are skipped, and a
value's own `"..."` or `'...'` quoting is stripped (`\\` and `\"` unescaped
inside double quotes), so `SECURITY_SYM_KEYS='["…"]'` stores the JSON the app
parses instead of a string that still has quotes in it.

```sh
./deploy.sh env set HOST APP KEY=VALUE [KEY=VALUE ...]  # inline values
./deploy.sh env set HOST APP KEY                        # hidden prompt
./deploy.sh env ls HOST APP                             # key names only
./deploy.sh env get HOST APP KEY                        # just the value
./deploy.sh env rm HOST APP KEY                         # delete a key
./deploy.sh env import HOST APP FILE|-                  # bulk KEY=value lines
./deploy.sh env edit HOST APP                           # $EDITOR, then upload
```

## Server prerequisites (per host)

- `systemd --user` with `loginctl enable-linger <user>`.
- `uv` / `node`+`pnpm`

## Layout

| Path | What |
| --- | --- |
| `~/deploy/post-receive` | the hook; every repo's `hooks/post-receive` symlinks to it |
| `~/deploy/repos/<app>` | bare repo — the push target |
| `~/deploy/live/<app>!<hash>` | one release dir per commit |
| `~/deploy/live/<app>!CURRENT` | symlink to the deployed release; the unit's cwd |
| `~/deploy/shared/<app>/env` | optional environment file; `EnvironmentFile=-` in the unit, exported to the deploy commands |
| `~/deploy/shared/<app>/deploy.conf` | optional command overrides |
| `~/.config/systemd/user/<app>.service` | generated; regenerated when it differs |

## Detection and overrides

| Tree contains | Sync | Build | Exec |
| --- | --- | --- | --- |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` | `pnpm build`, if defined | `pnpm start` |
| `uv.lock` | `uv sync --locked --no-dev` | — | `.venv/bin/python main.py` |

Anything else goes in `~/deploy/shared/<app>/deploy.conf` (server-side,
`sh`-sourced), managed from the desktop like env:

```sh
./deploy.sh conf set HOST APP EXEC=".venv/bin/python main.py"
./deploy.sh conf set HOST APP BUILD="pnpm build" UNIT_ENV="A=1 DATA_DIR={shared}/data"
./deploy.sh conf get|ls|rm|import|edit|show HOST APP ...
```

`conf set` and `conf import` accept only the five keys below, so an `EXE=` typo
fails (exit 2) instead of sitting in the file doing nothing; `conf rm` removes
any key, including hand-written ones. An imported value may carry the file's own
quoting, as in the example below — `conf import` strips the outer pair, so
`SYNC="uv sync"` stores `uv sync`, not the quotes. Values are stored verbatim as single-quoted
shell words — no `$VAR` expansion server-side, `{...}` placeholders still apply —
and only the touched line is rewritten, so comments and ordering survive. The
merged file is `sh -n`-checked before upload; `conf edit` checks it too and only
warns about extra keys. Nothing restarts: the hook re-reads the file on the next
push, and a changed SYNC/AFTER_SYNC/BUILD/EXEC/UNIT_ENV regenerates the unit
then.

```sh
SYNC="uv sync --locked --no-dev"
AFTER_SYNC="uv run --no-dev oban install"
BUILD="pnpm build"
EXEC=".venv/bin/python main.py"
UNIT_ENV="PYTHONUNBUFFERED=1 DATA_DIR={shared}/data"
```

`{repo}`, `{hash}`, `{root}`, `{live}`, `{live_curr}`, `{shared}` expand;
`UNIT_ENV` is one `Environment=` per word. A command still empty after detection
is a hard error naming this file.

`SYNC`, `AFTER_SYNC` and `BUILD` run through `sh -e -c` in the release dir, so a
value may be several commands and a failure anywhere stops the deploy:
`BUILD="uv run scripts/recreate_db.py; pnpm run build"`. `EXEC` is an
`ExecStart=` line instead — one process, no shell, so no `;`, `&&` or `$VAR`
(unquoted `uv` is fine: the unit's PATH starts with `~/.local/bin`).

## Hook updates

Git reads the shared file fresh on every push, so one write updates every app:

```sh
./deploy.sh init HOST APP   # any APP refreshes it; or, repo untouched:
ssh HOST 'cat > ~/deploy/post-receive && chmod 755 ~/deploy/post-receive' < post-receive
```

## Notes

- `deploy.sh` may be symlinked onto `PATH` (e.g. `~/bin/deploy.sh`): it
  resolves its own location, so `init` finds the `post-receive` next to the
  real file rather than next to the link.
- Command strings are shell snippets: a `;` or `&&` in `SYNC`/`AFTER_SYNC`/
  `BUILD` separates commands rather than becoming part of a filename.
- That shell also has the app's env, so a seeding or migration script in
  `BUILD` connects with the app's role rather than the server's OS user. The
  file is read the way systemd reads `EnvironmentFile=`: values are literal, so
  a `$` in a password or secret is kept, not expanded.
- `refs/heads/master` only (`DEPLOY_REF` overrides); branch deletes no-op.
- Each deploy prunes every other release dir for the app, so rollback is a
  re-push of the old commit, not a symlink flip. Re-pushing the deployed commit
  is safe (its dir is not cleared).
- A failed deploy removes the release dir it was building and leaves `CURRENT`
  alone, and every push first clears release dirs left by earlier failures, so
  `live/` holds one dir per app plus the one in flight.
- Hook failures don't fail the push: they print `post-receive: DEPLOY FAILED:
  <reason>` and activate nothing, though the ref has advanced — retry with
  `git commit --allow-empty -m redeploy && git push deploy master`.

## Testing

`sh test.sh` sandboxes the hook and `deploy.sh` (fake tools, stub `ssh`, real
pushes); `FRAMER=<repo>` adds a real app tree, `FRAMER=` skips it. Run it before
installing a change anywhere.
