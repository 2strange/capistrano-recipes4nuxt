# ✅ v1.0.0 — released (2026-06-12)

The first real **Nuxt 3 SSR deploy** has been verified on a staging test site
(Nitro systemd service, proxy → Nitro direct, health-check green, neighbouring sites
on the shared host stayed up) — the WIP lock is lifted.

**Recommended for NEW Nuxt 3 SSR projects.** For **existing and pure Nuxt 2 apps**,
[capistrano-nuxt2](https://github.com/2strange/capistrano-nuxt2) remains an **equally valid
standard** — no forced migration.

- **Migration nuxt2 → Nuxt 3 SSR:** [`docs/migration-nuxt2-to-nuxt3-ssr.md`](docs/migration-nuxt2-to-nuxt3-ssr.md)
- **Deploy contract / architecture:** [`docs/DEPLOY_CONTRACT.md`](docs/DEPLOY_CONTRACT.md)
- **Canonical deploy sequence:** `setup` → `deploy` (ssl:false) → `certbot:generate` → ssl:true → `deploy`
- ℹ️ **Content refresh (A2, swr + purge):** the purge endpoint is app/layer territory — reference
  implementation lives in `nuxt3_layer` (`server/api/_purge.post.ts`); the mechanism relies on
  Nitro internals → pin the tested Nitro version + run the smoke-test (`docs/PURGE_SMOKE_TEST.md`).

---

# Capistrano::Recipes4nuxt

Capistrano recipes to deploy **Nuxt 2 and Nuxt 3** apps — proxy-ready, nvm-aware, nginx + certbot included.

**Successor to [capistrano-nuxt2](https://github.com/2strange/capistrano-nuxt2)** — version-agnostic, compatible with the `recipes2go` setup including its proxy config.


## Usage

prepare the server:
```sh
bundle exec cap production setup
```

deploy the app:
```sh
bundle exec cap production deploy
```

create SSL certificates:
```sh
bundle exec cap production certbot:generate
```

## Installation

Inside your **Nuxt project root**, run:

```sh
bundle init
```

Then, edit the `Gemfile` and add:

```ruby
source "https://rubygems.org"

gem "capistrano-recipes4nuxt", require: false, github: "2strange/capistrano-recipes4nuxt"
```

Then, install the dependencies:

```sh
bundle install
```

#### Initialize Capistrano

```sh
bundle exec cap install
```

This will generate the following files:
```
.
├── Capfile
├── config
│   ├── deploy.rb
│   ├── deploy
│   │   ├── production.rb
│   │   ├── staging.rb
│   │   ├── development.rb
│   │   └── shared.rb
├── lib
│   └── capistrano
│       └── tasks
└── ...
```

#### Add the following to your `Capfile`:

```ruby
require "capistrano/recipes4nuxt"
## or selectively:
require "capistrano/recipes4nuxt/nuxt"       # Nuxt 2 build + deploy tasks
require "capistrano/recipes4nuxt/nuxt3"      # Nuxt 3 (SSR + static) tasks
## for certbot
require "capistrano/recipes4nuxt/certbot"
## for nginx
require "capistrano/recipes4nuxt/nginx"
## for nginx with a proxy server
require "capistrano/recipes4nuxt/proxy_nginx"
```

#### Add the following to your `config/deploy.rb`:

```ruby
set :application, "my-nuxt-app"
set :repo_url,    "git_path_to_your_repo"
```

#### Add the following to your `config/deploy/-STAGE-.rb`:

```ruby
server  "SERVER_DOMAIN_OR_IP",  user: "DEPLOY_USER",   roles: %w{web}

set :user,                            "DEPLOY_USER"
set :deploy_to,                       "/home/#{fetch(:user)}/#{fetch(:application)}-#{fetch(:stage)}"

set :branch,                          'STAGE_BRANCH'

## NginX
set :nginx_domains,                   ["YOUR_DOMAIN"]
set :nginx_remove_www,                true

## ssl-handling
set :nginx_use_ssl,                   true
set :certbot_email,                   "YOUR_EMAIL"
```

#### For nginx with a proxy server

```ruby
server "100.200.300.23", user: "deploy", roles: %w{app web}
server "100.200.300.42", user: "deploy", roles: %w{proxy}, no_release: true

set :user,                            "DEPLOY_USER"
set :deploy_to,                       "/home/#{fetch(:user)}/#{fetch(:application)}-#{fetch(:stage)}"

set :branch,                          'STAGE_BRANCH'

set :nginx_upstream_host,             "100.200.300.23"
set :nginx_upstream_port,             "3550"

## NginX
set :nginx_domains,                   ["YOUR_DOMAIN"]

## ssl-handling
set :nginx_use_ssl,                   true
set :certbot_email,                   "YOUR_EMAIL"
```

---

## Nuxt 3

The `nuxt3:` tasks deploy Nuxt 3 apps. Nuxt 3 builds into `.output/`
(`.output/server/index.mjs` for SSR, `.output/public/` for static assets),
not `dist/`. Two modes are supported:

- **SSR (default):** `nuxt build` -> the Nitro server runs as a systemd service
  (`node .output/server/index.mjs`), with the existing proxy in front of it.
- **Static:** `nuxt generate` -> `.output/public/` is synced to `shared/www`
  and served directly by nginx (no node service). Good for content sites.

Opt-in, leaves the Nuxt 2 `nuxt:` tasks untouched. Add to your `Capfile`:

```ruby
require "capistrano/recipes4nuxt/nuxt3"
## plus proxy + certbot as needed
require "capistrano/recipes4nuxt/proxy_nginx"
require "capistrano/recipes4nuxt/certbot"
```

#### SSR app -- `config/deploy/-STAGE-.rb`

```ruby
server "100.200.300.23", user: "deploy", roles: %w{app web}
server "100.200.300.42", user: "deploy", roles: %w{proxy}, no_release: true

set :user,                  "DEPLOY_USER"
set :deploy_to,             "/home/#{fetch(:user)}/#{fetch(:application)}-#{fetch(:stage)}"
set :branch,                'STAGE_BRANCH'

## Nuxt 3 SSR (Nitro node service)
set :nuxt3_deploy_mode,     :ssr            # default
set :nuxt3_use_nvm,         true
set :nuxt3_nvm_version,     "20.19.0"
set :nuxt3_ssr_port,        3500            # Nitro listens here (127.0.0.1)
set :nuxt3_ssr_env,         { "NUXT_PUBLIC_API_BASE" => "https://api.example.com" }

## Proxy points at the Nitro service
set :nginx_upstream_host,   "100.200.300.23"
set :nginx_upstream_port,   fetch(:nuxt3_ssr_port)

## NginX / SSL
set :nginx_domains,         ["YOUR_DOMAIN"]
set :nginx_use_ssl,         true
set :certbot_email,         "YOUR_EMAIL"
```

#### Static site -- `config/deploy/-STAGE-.rb`

```ruby
server "SERVER_DOMAIN_OR_IP", user: "DEPLOY_USER", roles: %w{web}

set :user,                  "DEPLOY_USER"
set :deploy_to,             "/home/#{fetch(:user)}/#{fetch(:application)}-#{fetch(:stage)}"
set :branch,                'STAGE_BRANCH'

set :nuxt3_deploy_mode,     :static
set :nuxt3_use_nvm,         true
set :nuxt3_nvm_version,     "20.19.0"

## NginX / SSL (serves shared/www directly)
set :nginx_domains,         ["YOUR_DOMAIN"]
set :nginx_use_ssl,         true
set :certbot_email,         "YOUR_EMAIL"
```

The `deploy:published` hook rebuilds automatically per `:nuxt3_deploy_mode`.
Manage the SSR service with `cap <stage> nuxt3:ssr:{setup,activate,restart,check_status,logs}`.

**Content-Refresh (A2):** SSR content routes use `swr` + an on-demand purge endpoint
instead of a rebuild. The gem ships the *mechanism* (the runtime ENV file carries the
purge token, the proxy/Nitro port is the curl target) plus a **purge smoke-test
harness** (`docs/purge-smoke-test.sh`) and a **Nitro version-pin** recommendation
(`docs/PURGE_SMOKE_TEST.md`). The purge endpoint itself (`server/api/_purge`) and the
`swr`-routeRules are **app/layer code, not the gem** — see
`docs/migration-nuxt2-to-nuxt3-ssr.md` §10–§11.

**First SSR deploy** (the systemd unit does not exist yet, so an auto-restart
would fail -- same as puma/sidekiq):

```ruby
set :nuxt3_ssr_hooks, false   # in the stage file, for the first deploy only
```

```sh
cap <stage> deploy              # builds + syncs .output (no restart)
cap <stage> nuxt3:ssr:configure # uploads + enables + starts the Nitro unit
```

Then set `nuxt3_ssr_hooks` back to `true` (the default) so subsequent deploys
restart the service cleanly.

---

## Next.js

`require "capistrano/recipes4nuxt/next"` deploys a Next.js app that runs with
`next start` (no `output: "standalone"` needed). Own `next_*` settings; the Nuxt
recipes are untouched. **Don't** combine it with `capistrano/recipes4nuxt`
(Nuxt 2) or `.../nuxt3` in the same Capfile — the deploy refuses that.

Per deploy (atomic — a red build or failed migration never goes live):

1. `deploy:starting` — upload `config/next_env/<stage>.env` → `shared/config/next.env` (0600)
2. `deploy:updated` — `npm ci` **per release**, `next build` (ENV sourced, so
   `NEXT_PUBLIC_*` is baked in), then `:next_pre_publish_cmds` (e.g. migrations)
3. `deploy:published` — restart the systemd unit (first deploy: create + enable), curl health-check

```ruby
# Capfile
require "capistrano/recipes4nuxt/next"
require "capistrano/recipes4nuxt/proxy_nginx"
require "capistrano/recipes4nuxt/certbot"
require "capistrano/recipes4nuxt/timers"     # optional
require "capistrano/recipes4nuxt/postgres"   # optional
```

```ruby
# config/deploy/production.rb
server "SERVER", user: "deploy", roles: %w{app db}
server "PROXY",  user: "deploy", roles: %w{proxy}, no_release: true

set :next_use_nvm,          true
set :next_nvm_version,      "24.16.0"
set :next_port,             3500
set :next_secrets_dir,      "config/secrets"   # created 0700, you fill it (one file per key)
set :next_pre_publish_cmds, ["npx tsx scripts/migrate.ts"]

set :nginx_upstream_host,   "SERVER"
set :nginx_upstream_port,   fetch(:next_port)
set :nginx_proxy_forwarded_for, "$remote_addr" # if the app rate-limits by X-Forwarded-For
```

Secrets go into `next.env` or the secrets dir — never into `:next_env` (the unit
file is world-readable). `cap <stage> next:check_env` warns about `NEXT_PUBLIC_*`
names that look like secrets. Tasks: `next:{setup_app,upload_env,check_env,build,
configure,restart,verify,start,stop,status,logs}`.

### Timers (`capistrano/recipes4nuxt/timers`)

Recurring jobs as systemd timers (cron replacement), framework-agnostic:

```ruby
set :systemd_timers, [
  { name: "purge", command: "npx tsx scripts/purge-expired.ts",
    on_calendar: "hourly", env: { "PURGE_ELEVENLABS" => "1" } },
]
```

Runs in `current/` with the app's ENV files, `flock` by default (no overlap).
Set up on every deploy; timers removed from the list are removed on the server.
`cap <stage> timers:{list,run[name],logs[name]}`. Lives here for now — port to
recipes2go when a Rails app needs it.

### PostgreSQL (`capistrano/recipes4nuxt/postgres`)

Creates login roles + the database on a local PostgreSQL (installing PostgreSQL
is server setup) and writes the connection URLs to `shared/config/database.env`
(0600, loaded by the app, build, migrations and timers). Passwords are generated
server-side-only and never appear on a command line. Grants/RLS stay in your
migrations.

```ruby
set :postgres_database,   "mary_production"   # default: <application>_<stage>
set :postgres_extensions, ["pgcrypto"]
set :postgres_db_roles, [
  { name: "app_owner",   attributes: "BYPASSRLS",   env: "DATABASE_OWNER_URL", owner: true },
  { name: "app_user",    attributes: "NOBYPASSRLS", env: "DATABASE_URL" },
  { name: "app_service", attributes: "BYPASSRLS",   env: "DATABASE_SERVICE_URL" },
]
```

`cap <stage> setup` runs `postgres:setup` (idempotent). An existing role whose URL
isn't in `database.env` aborts the setup (it may belong to another app) — take it
over explicitly with `postgres:rotate_password[role]`. `postgres:status` shows the
state without secrets.

---

## CHANGELOG

### 0.8.0 — Stage 2: A2 content refresh (gem side) — G14 + G15
- **G14 (gem part):** documented the ENV/port contract for the A2 purge endpoint
  (`docs/migration-nuxt2-to-nuxt3-ssr.md` §10) — the BE→Nitro `curl` targets
  `nuxt3_ssr_host:nuxt3_ssr_port`, the auth token rides in the existing ENV file
  (`nuxt3_ssr.env`). The `purging|admin-interface` flag state is **honestly scoped**:
  it is written **by the BE/admin path**, **not** by the deploy gem (only the read
  contract + file seeding belong to the gem). Docs in `base_helpers.rb` + Contract §3.2.
- **G15 (gem part):** shipped a Nitro/Nuxt **version-pin recommendation** + a purge
  **smoke-test harness/template** (`docs/purge-smoke-test.sh` + `docs/PURGE_SMOKE_TEST.md`),
  rationale = the undocumented routeRules cache purge (nuxt#20495).
- **The purge endpoint itself (`server/api/_purge`) + the `swr` routeRules are
  app/layer territory, NOT gem code.** The consumer fulfils the G15 requirement with
  THEIR endpoint.
- **§5 1.0 definition split honestly:** **1.0-A = gem deploy 1.0** (deploy core,
  release-ready after the pending re-deploy verify) vs. **1.0-B = full A2 feature**
  (FE/BE follow-up, not a gem blocker).
- Smoke test `test/a2_content_refresh_smoke_test.rb` green.

### 0.6.0 – 0.7.0 — SSR 1.0 stage 1 (deploy core, P0 gaps)
- **G1** ENV-file contract (`EnvironmentFile=-…/nuxt3_ssr.env` + `ssr:upload_env`/`check_env`).
- **G2** completed the flag states (`restarting|deploy`, `ERROR-<task>|deploy`).
- **G3** build-ENV sourcing (build ENV = runtime ENV) + `tee` build-log fix in the nvm branch.
- **G4** first-deploy ergonomics (unit auto-detect → `ssr:configure` instead of restart).
- **G5** health-check `nuxt3:ssr:verify` after restart (curl + retry, deploy fails loudly).
- **G12** neutral deploy-mode var `NUXT_APP_ENV`.
- **G16** cross-host bind (`nuxt3_ssr_host=0.0.0.0`) + decoupled health-check host;
  port isolation = operator infra (Tailscale), not the gem.
- **Q5 softener** `proxy_next_upstream` zero-config in the proxy_nginx template.
- **G17** (0.7.0) app-nginx `:ssr` port collision (was a 502 incident) fixed deploy_mode-aware.
- **G18** (0.7.0) base-require Nuxt2 hook footgun fixed deploy_mode-aware.

### 0.5.0 — Initial release (forked from capistrano-nuxt2 0.2.18; SSR still WIP → 1.0 once complete)
- Forked from `capistrano-nuxt2` v0.2.18
- Renamed gem to `capistrano-recipes4nuxt` (version-agnostic, matches `recipes2go` naming)
- Ruby module namespace changed: `Capistrano::Nuxt2` -> `Capistrano::Recipes4nuxt`
- Require paths changed: `capistrano/nuxt2` -> `capistrano/recipes4nuxt`
- Nuxt 2 and Nuxt 3 deploy tasks, nginx, proxy-nginx, certbot, vue tasks -- all carried over unchanged

---

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
