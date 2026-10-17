# deploy

One-file push-to-deploy for the `~/deploy` layout. `post-receive` is POSIX sh,
stdlib-free, and installs nothing: one copy lives at `~/deploy/post-receive` on
the host, every repo's `hooks/post-receive` is a symlink to it, and a hook
update is overwriting that single file.

## New server, per app

```sh
# 1. dirs, bare repo, and the shared hook (from a checkout of this repo)
./init-app.sh eli@sg1 framer

# 2. the app's environment (secrets; the hook refuses to deploy without it)
ssh eli@sg1 'mkdir -p ~/deploy/shared/framer && printf "DATABASE_URL=%s\n" "postgresql://..." > ~/deploy/shared/framer/env'

# 3. push
git remote add deploy eli@sg1:deploy/repos/framer
git push deploy master
```

`init-app.sh HOST APP` does that first step over ssh: `mkdir -p` for
`~/deploy/repos`, `~/deploy/live` and `~/deploy/shared/<app>`, `git init --bare`
for the repo, the `post-receive` next to the script into `~/deploy/post-receive`,
and a `hooks/post-receive` symlink in the repo pointing at it. Re-running it
refreshes the shared hook — for every app on the host — and restores the symlink,
leaving the repo, refs and files alone.

The hook deploys into `~/deploy/live/`, writes the systemd user unit on first
deploy, and prunes the release it replaced.

## Updating the hook

Every app symlinks the same `~/deploy/post-receive`, and git reads it fresh on
every push, so one write updates every app on the host:

```sh
./init-app.sh HOST APP   # refreshes the shared hook for any APP on HOST

# or, without touching a repo:
ssh HOST 'cat > ~/deploy/post-receive && chmod 755 ~/deploy/post-receive' < post-receive
```

Apps set up before the symlink existed keep their own copy of the hook; run
`init-app.sh HOST APP` once per app to switch them over, or in one pass:

```sh
ssh HOST 'for r in ~/deploy/repos/*; do ln -sfn ../../../post-receive "$r/hooks/post-receive"; done'
```

## Server prerequisites (per host, one time)

- `systemd --user`: `loginctl enable-linger <user>` so the service survives logout.
- The runtime the app needs, on the service's `PATH`
  (`%h/.local/bin:/usr/local/bin:/usr/bin:/bin`): `uv` for Python apps, `node` +
  `pnpm` for Node apps. For a pnpm app, pnpm must be new enough to honour the
  repo's build-approval fields (`allowBuilds` / `allowScripts`), or sharp and
  esbuild skip their install scripts and the build fails.

## Layout it owns

| Path | What |
| --- | --- |
| `~/deploy/post-receive` | the hook itself; every repo's `hooks/post-receive` symlinks to it |
| `~/deploy/repos/<app>` | bare repo — the push target |
| `~/deploy/live/<app>!<hash>` | one release dir per commit |
| `~/deploy/live/<app>!CURRENT` | symlink to the deployed release; the unit's cwd |
| `~/deploy/shared/<app>/env` | environment file, `EnvironmentFile=` in the unit |
| `~/deploy/shared/<app>/deploy.conf` | optional command overrides |
| `~/.config/systemd/user/<app>.service` | generated; regenerated when it differs |

The unit runs `ExecStart` with `WorkingDirectory` at `CURRENT`, `Restart=on-failure`,
and the shared env file. `systemctl --user status <app>` and `journalctl --user -u <app>`
are the debug tools; nothing wraps them.

## Commands: detected, not configured

| Tree contains | Sync | Build | Exec |
| --- | --- | --- | --- |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` | `pnpm build`, if `package.json` defines it | `pnpm start` |
| `uv.lock` | `uv sync --locked --no-dev` | — | `.venv/bin/python main.py` |

Both stacks resolve their absolute binary paths at push time, so the commands in
the unit survive a non-interactive `PATH`.

## Overrides: `deploy.conf`

Optional, server-side, `sh`-sourced, every key optional. Use it when a repo
doesn't fit the table above:

```sh
# ~/deploy/shared/<repo>/deploy.conf
SYNC="uv sync --locked --no-dev"
AFTER_SYNC="uv run --no-dev oban install"
BUILD="pnpm build"
EXEC=".venv/bin/python main.py"
UNIT_ENV="PYTHONUNBUFFERED=1 DATA_DIR={shared}/data"
```

- `UNIT_ENV` is space-separated and becomes one `Environment=` line each.
- `{repo}`, `{hash}`, `{root}`, `{live}`, `{live_curr}`, `{shared}` expand.
- Anything still empty after detection is a hard error naming this file, so a
  deploy never silently skips its own build.
- Change the file, push again: the unit is regenerated automatically.

## Notes

- Only `refs/heads/master` deploys (set `DEPLOY_REF` in the unit's environment
  to change it); a branch deletion is a no-op.
- After a successful restart, every other release dir for that app is pruned —
  the one just replaced, and any left behind by a failed deploy. Rollback is
  therefore a re-push of the old commit, not a symlink flip.
- Re-pushing the commit `CURRENT` already points at doesn't clear its dir, so a
  self-redeploy can't yank the running release's files.
- git does not fail a push when a `post-receive` hook fails. Failures therefore
  print `post-receive: DEPLOY FAILED: <reason>` and activate nothing. The failed
  push *does* already advance the ref, so retry with a new commit —
  `git commit --allow-empty -m redeploy && git push deploy master` — and the
  half-made release is cleaned up by that retry.
- `deploy.conf` lives only in the shared dir; it is never copied into a release.

## Testing

`sh test.sh` runs the hook and `init-app.sh` against a sandbox: fake
`pnpm`/`uv`/`node`/`systemctl` early on `PATH`, a stub `ssh` that runs
`init-app.sh`'s remote half locally, `HOME` and the deploy root redirected into a
temp dir, real pushes into real bare repos. `FRAMER=<repo>` (default
`~/projects/framer`) adds a real app tree to the mix; set it empty to skip that
case. It asserts the release layout, unit contents, prune behavior, branch
filtering, self-redeploy safety, shared-hook symlinking, fresh-target setup and
every failure path —
worth running before installing a change anywhere, since one bad hook breaks
every app's deploy.
