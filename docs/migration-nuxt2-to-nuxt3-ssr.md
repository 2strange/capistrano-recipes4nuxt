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

## 10. Content-Refresh (A2) — `swr`-routeRules + Nitro-Purge-Endpoint

> **Worum es geht:** Der alte Admin-„Seite neu rendern"-Button (`nuxt generate` →
> rsync) **bleibt funktionell** — aber das Mittel ändert sich. In recipes4nuxt-SSR
> sind Content-Routen auf `swr` (stale-while-revalidate): nach TTL **automatisch
> frisch**, und der Admin-Button purged on-demand die Nitro-Route-Caches → nächster
> Request rendert sofort frisch. **Kein npm-Build mehr.** (Entscheid A2, Contract §6a.)

### ⚖️ Revier — was das Gem liefert vs. was DU (Consumer/FE) baust

A2 ist **bewusst klein auf der Gem-Seite**. Der Purge-Endpoint ist eine **Nitro-Server-Route
= App-/Layer-Code, NICHT das Deploy-Gem.** Klare Trennung:

| Baustein | Wer | Im Gem? |
|---|---|---|
| `swr`-routeRules in `nuxt.config.ts` | **Luke (FE/Layer)** | ❌ App-Code |
| `server/api/_purge`-Endpoint (`getKeys('nitro')` + `removeItem` — s. Layer-Referenz) + Auth | **Luke (FE/Layer)** — **gebaut + G15-verifiziert im `nuxt3_layer`** | ❌ App-Code (Nitro-Route) |
| BE-Worker: `npm run export` → authentifizierter `curl …/_purge` | **Bill (BE)** | ❌ BE-Code |
| Admin-Button + renderState-Texte | **Luke (FE)** | ❌ FE-Code |
| **ENV-File-Mechanismus** (Auth-Token landet in `nuxt3_ssr.env`) | **recipes4nuxt** | ✅ schon da (§4 / `ssr:upload_env`) |
| **Port/Host-Kontrakt** (auf was der BE-`curl` zielt) | **recipes4nuxt** | ✅ schon da (`nuxt3_ssr_host:nuxt3_ssr_port`) |
| `purging\|admin-interface`-Flag-State (Lesekontrakt der UI) | recipes4nuxt seedet die **Datei** (`linked_file`); **geschrieben** wird sie BE/Admin-seitig | ✅ Datei / ❌ Write |

**→ Das Gem stellt den _Mechanismus_ (ENV-File, Port, Flag-Datei) — den _Endpoint_ baust du.**
Es gibt **keinen** `nuxt3:*`-Task fürs Purgen; das ist Absicht (der Purge ist ein HTTP-Call
vom BE, kein Deploy-Schritt).

### Der ENV/Port-Kontrakt, an dem dein Endpoint andockt (Gem-Seite)

Damit BE→Nitro-Purge funktioniert, brauchst du nur drei Dinge — alle vom Gem schon bereitgestellt:

1. **Erreichbarkeit:** Nitro lauscht auf `fetch(:nuxt3_ssr_host):fetch(:nuxt3_ssr_port)`
   (Default `127.0.0.1:3500`). Liegt der BE-Worker auf **derselben Box**, purgt er gegen
   `127.0.0.1:<port>`. Liegt er **cross-host** (Proxy-Setup), zielt er auf `<app-lan-ip>:<port>`
   (= dieselbe Adresse wie der nginx-Upstream; `nuxt3_ssr_host` muss dann `0.0.0.0` sein, §6/§4.5).
   Der Health-Check-Host (`nuxt3_ssr_healthcheck_host`, Default `127.0.0.1`) ist der lokale Loopback —
   praktischer Default auch fürs Same-Box-Purgen.
2. **Auth-Token via ENV-File:** Lege das Purge-Token in `config/nuxt_env/<stage>.env`
   (z. B. `NUXT_PURGE_TOKEN=…`, gitignored). Es wird vom Gem nach `shared/config/nuxt3_ssr.env`
   hochgeladen (§4) **und** in den Nitro-Prozess geladen — dein `_purge`-Handler liest es via
   `runtimeConfig`, der BE-Worker schickt es als Header/Query mit. **Ein** Secret-Pfad, kein neues
   Gem-Feature nötig.
3. **Endpoint-Pfad-Konvention:** empfohlen `POST /api/_purge` (geschützt). Der Pfad ist FE-Sache;
   der BE-`curl` und der Endpoint müssen sich nur einigen.

### 📎 Kanonische Referenz-Implementierung (im Layer, **nicht** im Gem dupliziert)

Den Purge-Endpoint **nicht selbst nachbauen** — er ist im **`nuxt3_layer` gebaut + G15-verifiziert**.
**Single Source = der Layer** (das Gem schreibt die Mechanik bewusst nicht vor, sondern verweist):

> **Referenz:** `nuxt3_layer` → `server/api/_purge.post.ts`, Branch `feat/a2-purge-endpoint`
> (Commit `8a1a1ad`, v0.1.4). **Opt-in** (Endpoint ist deaktiviert/404, solange kein Token
> konfiguriert ist), Auth via `NUXT_PURGE_TOKEN` → `x-purge-token`-Header, konstant-zeitiger
> Vergleich (`timingSafeEqual`).

**Verifizierte Purge-Mechanik** (gegen nuxt 3.21.6 / nitropack 2.13.4 / unstorage 1.17.5):
`getKeys('nitro')` aufzählen und **pro Key `removeItem(key)`** — **nicht** `clear(prefix)`.

> ⚠️ **Stiller Failure-Mode (genau dafür ist der G15-Smoke-Test Pflicht):** der früher hier
> dokumentierte Weg `useStorage('cache').clear('nitro:routeRules')` ist **doppelt falsch** —
> (1) der echte Cache-Key-Prefix ist `nitro:routes:…`, **nicht** `nitro:routeRules`, und
> (2) `clear(prefix)` ist auf den colon-namespaced Keys (unstorage 1.17.5, Default Memory-/FS-Driver)
> ein **No-op**: es löscht **nichts**, der Endpoint antwortet trotzdem `200`, der Cache bleibt stale
> → **stiller Prod-Failure** (Admin drückt „aktualisieren", nichts passiert). Verifiziert von Luke
> beim echten G15-Test (s. §11).

```rb
# BE-Worker (Bill): statt `npm run export` →
`curl -fsS -X POST -H "x-purge-token: #{ENV['NUXT_PURGE_TOKEN']}" http://127.0.0.1:#{port}/api/_purge`
```

## 11. Nitro-Version-Pin + Purge-Smoke-Test (A2-Pflicht-Auflage, G15)

> ⚠️ **Pflicht, nicht optional.** Der Purge (`getKeys('nitro')` + `removeItem`, s. Layer-Referenz
> §10) räumt einen routeRules-`swr`-Cache über einen **internen, undokumentierten** Storage-Key-Prefix
> (`nitro:routes:…`) — es gibt **kein** First-Class-Invalidierungs-API für routeRules
> ([nuxt#20495](https://github.com/nuxt/nuxt/discussions/20495)). Ein Nitro-/unstorage-Upgrade kann das
> Key-Schema ändern und den Purge **lautlos ins Leere** laufen lassen (`200`, aber nichts gelöscht).
> **Beleg, warum der Smoke-Test Pflicht ist:** der frühere `clear('nitro:routeRules')`-Weg war genau
> so ein stiller No-op (verifiziert, unstorage 1.17.5) — er fiel erst im realen G15-Test auf.

**Auflage (erfüllt der Consumer):**
1. **Nitro/Nuxt pinnen** — in der Consumer-`package.json` eine **exakte, getestete** Version
   festnageln (kein Caret). Die im `nuxt3_layer` real verifizierte Referenz-Matrix:
   ```json
   { "dependencies": { "nuxt": "3.21.6" }, "overrides": { "nitropack": "2.13.4" } }
   ```
   Verifiziert gegen **nuxt 3.21.6 / nitropack 2.13.4 / unstorage 1.17.5 / node 24.16.0**. Gegen
   diese Matrix ist der Purge-Pfad (`getKeys('nitro')` + `removeItem`) grün. **Consumer pinnt exakt
   und re-verifiziert vor jedem Nuxt/Nitro-Bump** — die Mechanik ist **Nitro-intern** (nuxt#20495),
   ein Bump kann sie still brechen. (Getestete Referenz-Matrix: s. `docs/PURGE_SMOKE_TEST.md`.)
2. **Purge-Smoke-Test gegen DEINEN Endpoint** fahren — Vorlage + Anleitung liegen in
   `docs/purge-smoke-test.sh` + `docs/PURGE_SMOKE_TEST.md`. Er prüft real: Route cached → Purge →
   Route invalidiert/frisch. **Das Gem kann diesen Test nicht selbst fahren** (es gibt keinen
   Endpoint im Gem) — es liefert die **Vorlage**, scharf schaltest du sie mit deinem `_purge`-Endpoint.

## 12. Rollback

Den `:static`/`capistrano-nuxt2`-Stand auf einem **eigenen Branch** (z.B. `staging`)
unberührt halten. Bei SSR-Problemen den static-Branch redeployen → Seite ist sofort
zurück.

---
*Quelle: moja-Testbett, erster realer recipes4nuxt-SSR-Deploy (2026-06-12, Robert/moja
+ Tim/Cargo). Kanonisch gepflegt in `capistrano-recipes4nuxt/docs/` — Cargo/Tim halten
sie mit den Gem-Fixes aktuell. §3 + §7 (base-require-Hook-Footgun + App-Nginx-:ssr-
Kollision) sind ab Gem 0.7.0 deploy_mode-aware automatisch gefixt (Contract §5 G17/G18).
§10–§11 (Content-Refresh A2 + Purge-Smoke-Test/Version-Pin) = Gem-Seite 0.8.0; der
Purge-Endpoint selbst ist FE/Layer-Revier (Luke), kein Gem-Code (Contract §6a/G14/G15).*
