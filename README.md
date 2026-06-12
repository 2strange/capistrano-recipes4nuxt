# ✅ v1.0.0 — released (Stand 2026-06-12)

Der erste reale **Nuxt-3-SSR-Deploy** ist auf **`moja.freaks.technology`** verifiziert
(Nitro-systemd-Service, Proxy → Nitro direkt, Health-Check grün, Shared-Host-Nachbarn
stabil) — die WIP-Sperre ist aufgehoben.

**Empfohlen für NEUE Nuxt-3-SSR-Projekte.** Für **bestehende und reine Nuxt-2-Apps** bleibt
[capistrano-nuxt2](https://github.com/2strange/capistrano-nuxt2) ein **gleichwertiger
Standard** — kein Migrationszwang (Austin-Entscheid 2026-06-12).

- **Migration nuxt2 → Nuxt-3-SSR:** [`docs/migration-nuxt2-to-nuxt3-ssr.md`](docs/migration-nuxt2-to-nuxt3-ssr.md)
- **Deploy-Kontrakt / Architektur:** [`docs/DEPLOY_CONTRACT.md`](docs/DEPLOY_CONTRACT.md)
- **Kanonischer Deploy-Ablauf:** `setup` → `deploy` (ssl:false) → `certbot:generate` → ssl:true → `deploy` (myTOOLZ `docs/deploy-runbook.md`)
- ℹ️ **Content-Refresh (A2, swr + Purge):** der Purge-Endpoint ist FE-Revier — Referenz-Impl im `nuxt3_layer` (`server/api/_purge.post.ts`); Mechanik ist Nitro-intern → getestete Nitro-Version pinnen + Smoke-Test (`docs/PURGE_SMOKE_TEST.md`).

---

# Capistrano::Recipes4nuxt

Capistrano recipes to deploy **Nuxt 2 and Nuxt 3** apps — proxy-ready, nvm-aware, nginx + certbot included.

**Nachfolger von [capistrano-nuxt2](https://github.com/2strange/capistrano-nuxt2)** — version-agnostisch, kompatibel mit dem `recipes2go`-Setup inkl. Proxy-Config.


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

## CHANGELOG

### 0.8.0 — Etappe 2: A2 Content-Refresh (Gem-Seite) — G14 + G15
- **G14 (Gem-Teil):** ENV/Port-Kontrakt für den A2-Purge-Endpoint dokumentiert
  (`docs/migration-nuxt2-to-nuxt3-ssr.md` §10) — der BE→Nitro-`curl` zielt auf
  `nuxt3_ssr_host:nuxt3_ssr_port`, das Auth-Token reist im bestehenden ENV-File
  (`nuxt3_ssr.env`). `purging|admin-interface`-Flag-State **ehrlich abgegrenzt**:
  wird **vom BE/Admin-Pfad** geschrieben, **nicht** vom Deploy-Gem (nur Lesekontrakt
  + Datei-Seeding gehören dem Gem). Doku in `base_helpers.rb` + Contract §3.2.
- **G15 (Gem-Teil):** Nitro-/Nuxt-**Version-Pin-Empfehlung** + Purge-**Smoke-Test-
  Harness/Vorlage** geliefert (`docs/purge-smoke-test.sh` + `docs/PURGE_SMOKE_TEST.md`),
  Begründung = undokumentierter routeRules-Cache-Purge (nuxt#20495).
- **Der Purge-Endpoint selbst (`server/api/_purge`) + `swr`-routeRules = FE/Layer-Revier
  (Luke), KEIN Gem-Code.** Die G15-Auflage erfüllt der Consumer mit SEINEM Endpoint.
- **§5 1.0-Definition ehrlich gesplittet:** **1.0-A = Gem-Deploy-1.0** (Deploy-Kern,
  release-fähig nach dem ausstehenden Re-Deploy-Verify) vs. **1.0-B = volle A2-Funktion**
  (FE/BE-Follow-up, kein Gem-Blocker).
- Smoke `test/a2_content_refresh_smoke_test.rb` grün.

### 0.6.0 – 0.7.0 — SSR-1.0 Etappe 1 (Deploy-Kern, P0-Gaps)
- **G1** ENV-File-Kontrakt (`EnvironmentFile=-…/nuxt3_ssr.env` + `ssr:upload_env`/`check_env`).
- **G2** Flag-States vervollständigt (`restarting|deploy`, `ERROR-<task>|deploy`).
- **G3** Build-ENV-Sourcing (Build-ENV = Runtime-ENV) + `tee`-Build-Log-Fix im nvm-Zweig.
- **G4** Erst-Deploy-Ergonomie (Unit-Autodetect → `ssr:configure` statt Restart).
- **G5** Health-Check `nuxt3:ssr:verify` nach Restart (curl + Retry, Deploy failt laut).
- **G12** Neutrale Deploy-Mode-Var `NUXT_APP_ENV`.
- **G16** Cross-Host-Bind (`nuxt3_ssr_host=0.0.0.0`) + entkoppelter Health-Check-Host;
  Port-Isolation = Operator-Infra (Tailscale), nicht Gem.
- **Q5-Weichmacher** `proxy_next_upstream` zero-config im proxy_nginx-Template.
- **G17** (0.7.0) App-Nginx-:ssr-Port-Kollision (war 502-Incident) deploy_mode-aware gefixt.
- **G18** (0.7.0) base-require-Nuxt2-Hook-Footgun deploy_mode-aware gefixt.

### 0.5.0 — Erstrelease (forked von capistrano-nuxt2 0.2.18; SSR noch WIP → 1.0 sobald vollständig)
- Forked from `capistrano-nuxt2` v0.2.18
- Renamed gem to `capistrano-recipes4nuxt` (version-agnostic, matches `recipes2go` naming)
- Ruby module namespace changed: `Capistrano::Nuxt2` -> `Capistrano::Recipes4nuxt`
- Require paths changed: `capistrano/nuxt2` -> `capistrano/recipes4nuxt`
- Nuxt 2 and Nuxt 3 deploy tasks, nginx, proxy-nginx, certbot, vue tasks -- all carried over unchanged

---

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
