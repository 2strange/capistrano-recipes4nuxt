# Migration: `capistrano-nuxt2` → `capistrano-recipes4nuxt` (Nuxt 3 SSR)

> **Upgrade-Anleitung:** einen App-Deploy von `capistrano-nuxt2` (Nuxt-2-SSR bzw.
> Nuxt-3-`static`-Generate) auf `capistrano-recipes4nuxt` im **Nuxt-3-SSR-Modus**
> (Nitro-systemd-Service) umstellen.
>
> Erstfassung destilliert aus dem **moja-Testbett** — dem ersten realen
> recipes4nuxt-SSR-Deploy (Robert/moja + Tim/Cargo, 2026-06-12). Die dort
> aufgedeckten zwei Bugs (§3 base-require-Hook-Footgun, §7 App-Nginx-:ssr-Port-
> Kollision) sind **ab Gem 0.7.0 deploy_mode-aware automatisch gefixt** — kein
> Consumer-Workaround mehr nötig (Details unten + `docs/DEPLOY_CONTRACT.md` §5
> G17/G18).

## Was sich ändert (Modell)

| | Alt (`capistrano-nuxt2`) | Neu (`recipes4nuxt` `:ssr`) |
|---|---|---|
| App | `ssr: false` (SPA) bzw. Nuxt-2-SSR | `ssr: true` (Nuxt 3) |
| Build | `nuxt generate` → static `.output/public` | `nuxt build` → `.output/server` (Nitro) + `.output/public` |
| Serving | App-nginx liefert statische Dateien (SPA-Fallback) | **systemd-Service** `node .output/server/index.mjs` (Nitro) |
| nginx | Proxy → App-nginx (file-root) | Proxy (SSL-Terminator) → **Nitro direkt** (`nuxt3_ssr_port`) |
| Content-Refresh | Admin → `nuxt generate` → rsync | A2: `swr` + interner Nitro-Purge-Endpoint (BE `curl`) |

## 1. App-Code (`nuxt.config.ts`)

- `ssr: true`.
- **Deploy-mode-aware `extends`** (der Server hat keinen Sibling-Layer-Checkout):
  ```ts
  extends: [process.env.<DEPLOY_MODE> ? 'github:<org>/<layer>#<ref>' : '../../<layer>'],
  ```
  `<ref>` muss einen Layer-Stand mit dem eingecheckten `.nuxt/tsconfig.json`-Stub
  haben (sonst bricht der Build mit `TSConfckParseError: failed to resolve
  "extends":"./.nuxt/tsconfig.json"`). Tag-Pin bevorzugen.
- Daten via `onMounted` (client) rendern Shells server-seitig ohne Crash. Volle
  server-gerenderte Daten = `useAsyncData`/`useFetch` (eigener App-Port-Schritt,
  fürs Deploy-Mechanik-Testbett nicht nötig).

## 2. `Gemfile`

```ruby
gem "capistrano-recipes4nuxt", require: false, github: "2strange/capistrano-recipes4nuxt", branch: "feat/ssr-1.0" # bzw. Version-Tag
```
`bundle install`. Der npm-Build läuft **server-seitig via nvm**.

## 3. `Capfile` — der minimale SSR-Set

```ruby
require "capistrano/recipes4nuxt/nuxt3"        # Nuxt 3 SSR (deploy_mode-aware deploy:published-Hook)
require "capistrano/recipes4nuxt/proxy_nginx"  # shared SSL-Terminator -> Nitro
require "capistrano/recipes4nuxt/certbot"
```

✅ **Ab 0.7.0 automatisch (deploy_mode-aware) — kein Consumer-Workaround mehr nötig.**
Das obige ist der **empfohlene, schlanke** SSR-Set. Falls dennoch `require
"capistrano/recipes4nuxt"` (base) bzw. `.../nuxt` mitgeladen wird (z. B. aus einer
gemischten App), ist das **kein Footgun mehr**: die Nuxt2-`nuxt.rake` ist
deploy_mode-aware — ihr `after 'deploy:published'`-Rebuild-Hook **feuert nicht**,
sobald `nuxt3_deploy_mode` gesetzt ist (`:ssr`/`:static`). So entfällt die
frühere Kollision mit dem nuxt3-SSR-Hook **und** das `npm install` ohne nvm
(`exit 127`). Der minimale Set oben bleibt trotzdem die saubere Empfehlung.
*(Gem-Detail: `DEPLOY_CONTRACT.md` §5 G18.)*

> ⚠️ **Falls auf älterem Gem (< 0.7.0):** dort zog der base-require die Nuxt2-
> `nuxt.rake` mit aktivem Rebuild-Hook → Kollision + `exit 127, npm: No such file
> or directory`. Dann **NUR** den minimalen Set oben laden (kein base/`nuxt`/`nginx`).
> Ab 0.7.0 nicht mehr nötig.

## 4. ENV-File-Kontrakt

- Lokal `config/nuxt_env/<stage>.env` (**gitignored**), eine `.env.example`-Vorlage **committen**.
- Hier rein: Build-Zeit-Vars (Deploy-mode-Flag fürs `extends`, `NUXT_PUBLIC_API_BASE`) **und** SSR-Runtime-Vars.
- `.gitignore`: `/config/nuxt_env/*.env` + `!/config/nuxt_env/*.env.example`.
- Wird beim Deploy nach `shared/config/nuxt3_ssr.env` hochgeladen (systemd
  `EnvironmentFile`, File-Werte gewinnen) UND beim Build gesourct.
- ⚠️ Leeres/fehlendes ENV-File → Build zieht ggf. den falschen (local-path-)Layer
  → bricht. Vor dem Deploy real anlegen.

## 5. `config/deploy/<stage>.rb`

```ruby
set :nuxt3_deploy_mode,   :ssr
set :nuxt3_ssr_port,      3500          # Nitro-Port, pro Box eindeutig (freier Bereich!)
set :nuxt3_ssr_host,      '0.0.0.0'     # NUR nötig wenn Proxy CROSS-HOST auf Nitro muss; same-host reicht default 127.0.0.1
set :nginx_upstream_host, '<app-lan-ip>'
set :nginx_upstream_port, fetch(:nuxt3_ssr_port)   # Proxy -> Nitro direkt
set :nuxt3_npm_install_cmd, "ci --include=dev"     # devDeps = Build-Toolchain (sonst postinstall exit 127)
# nvm, certbot_*, nginx_domains, nginx_use_ssl wie gehabt
# KEINE manuellen proxy_next_upstream-Zeilen (Q5 macht das proxy_nginx-Template zero-config)
# KEIN nginx_app_hooks-Flag nötig (ab 0.7.0 defaultet :ssr automatisch auf false — s. §7)
# KEIN ufw_additional_ports (oeffnet den Port PUBLIC - s. §6)
```

⚠️ **`npm ci`** (Gem-Default) verlangt einen **in-sync committeten `package-lock.json`**
→ vor dem ersten Deploy `npm install` fahren, reviewen, den reconcilten Lock committen.

## 6. Firewall / Port-Restriktion — netz-abhängig, **T4**

Nitro auf `0.0.0.0:<ssr_port>` ist über Loopback hinaus erreichbar. Eine
Quell-Beschränkung (nur der Proxy darf ran) ist **optionales least-privilege-
Hardening**, **kein** public-exposure-Fix, wenn der App-Host nicht internet-facing
ist (z.B. Tailscale-gated, keine public Ports → nur intra-LAN/Tailnet erreichbar).

Falls nötig (public-facing / untrusted / multi-tenant): **manuelle, quell-beschränkte**
ufw-Regel auf dem App-Host: `ufw allow from <proxy-ip> to any port <ssr_port>
proto tcp`. **NICHT** `ufw_additional_ports` (öffnet den Port public — das Gegenteil)
und **nicht** recipes2go-`ufw` (macht `ufw --force reset` + kann keine `from`-Regeln).

## 7. App-Nginx im `:ssr`-Mode — ✅ ab 0.7.0 automatisch (kein App-Nginx mehr)

Im `:ssr`-Mode terminiert der **Proxy** SSL und proxyt **direkt auf den Nitro-Port**
(`nuxt3_ssr_port`). Einen **App-Nginx braucht es gar nicht** — der ist ein Artefakt
des `:static`-Modells (wo nginx die Files liefert).

✅ **Ab 0.7.0 automatisch (deploy_mode-aware) — kein Consumer-Workaround mehr nötig.**
Bei `set :nuxt3_deploy_mode, :ssr` defaultet `nginx_app_hooks` auf `false` und der
App-Nginx-Hook (`nginx:app:update`) wird übersprungen — der App-vhost wird weder
angelegt noch `nginx -t`/restart darauf ausgeführt. Ein zusätzlicher Hook-Guard
greift selbst dann, wenn ein altes Consumer-Config `nginx_app_hooks, true`
force-setzt. `:static`, nuxt2-Static und der reine Rails/recipes2go-Proxy-Fall
bleiben unberührt. *(Gem-Detail: `DEPLOY_CONTRACT.md` §5 G17.)*

> ⚠️ **Falls auf älterem Gem (< 0.7.0):** dort legte `proxy_nginx` im `:ssr`-Mode
> **trotzdem** einen App-Nginx auf `nginx_upstream_port` (= `nuxt3_ssr_port`) an →
> **kollidiert mit Nitro** auf demselben Port → `nginx -t` wird **host-weit**
> ungültig → `systemctl restart nginx` failt → **alle Sites auf dem App-Host
> liefern 502** (auf einem Shared-Host reißt das die Nachbarn mit!).
> - **Workaround auf altem Gem:** `set :nginx_app_hooks, false`.
> - **Recovery falls passiert:** `sudo rm /etc/nginx/sites-enabled/<app>_<stage>_app
>   && sudo nginx -t && sudo systemctl restart nginx`.
> Ab 0.7.0 ist der Workaround nicht mehr nötig (Default ist korrekt).

## 8. First-Deploy-Choreografie

```bash
cap <stage> setup
# Phase 1 (ssl:false), falls noch KEIN Cert existiert:
cap <stage> deploy
cap <stage> certbot:generate
# Phase 2 (ssl:true):
cap <stage> deploy
```

**Mode-Switch auf einer bereits live+SSL-Domain** (static→SSR): Cert/DNS existieren
→ `certbot:generate` ist faktisch ein No-op; ein `cap <stage> deploy` mit `ssl:true`
reicht meist. **Alle Folge-Deploys:** `cap <stage> deploy`.

## 9. Verify

- `curl -sI https://<domain>/` → `200`; Body **server-gerendert** (großes HTML,
  nicht die ~2 KB SPA-Shell).
- `cap <stage> nuxt3:ssr:check_status` → Unit `enabled` (boot-persistent) +
  `active (running)`, Log „Listening on http://0.0.0.0:<port>".
- `cap <stage> nuxt3:ssr:check_env` → ENV-File nicht leer.
- Health-Check `nuxt3:ssr:verify` läuft im Deploy-Hook (curl 127.0.0.1:<port> mit Retry).

## 10. Rollback

Den `:static`/`capistrano-nuxt2`-Stand auf einem **eigenen Branch** (z.B. `staging`)
unberührt halten. Bei SSR-Problemen den static-Branch redeployen → Seite ist sofort
zurück.

---
*Quelle: moja-Testbett, erster realer recipes4nuxt-SSR-Deploy (2026-06-12, Robert/moja
+ Tim/Cargo). Kanonisch gepflegt in `capistrano-recipes4nuxt/docs/` — Cargo/Tim halten
sie mit den Gem-Fixes aktuell. §3 + §7 (base-require-Hook-Footgun + App-Nginx-:ssr-
Kollision) sind ab Gem 0.7.0 deploy_mode-aware automatisch gefixt (Contract §5 G17/G18).*
