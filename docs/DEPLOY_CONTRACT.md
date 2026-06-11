# DEPLOY_CONTRACT.md — Nitro-SSR-Deploy-Kontrakt (recipes4nuxt)

> **Status: ✅ KONTRAKT FINALISIERT (alle Entscheide getroffen, Stand 2026-06-11)** —
> Branch `design/nitro-deploy-contract`. **Umsetzung blockiert bis recipes4nuxt-WIP-Entsperrung**
> (Merge-/Freigabe-Entscheid: Tim mit Austin). Dieses Dokument ist ab jetzt der **verbindliche
> Bau-Kontrakt** für SSR 1.0.
> Autor: Cargo (myTOOLZ release) · Stand: 2026-06-11 · Review: Tim → Austin.
>
> **Entscheid-Stand 2026-06-11 (alle 6 offenen Fragen geschlossen):**
> Q1 systemd (PM2 raus) = **DECIDED** · Q2 Admin-Rebuild-Trigger bleibt **funktionell erhalten**
> (Override des alten §3.2 „entfällt ersatzlos") = **DECIDED** · Q3 ENV-File = **DECIDED** ·
> Q4 `NUXT_APP_ENV` + Port-Regel = **DECIDED** · Q5 Restart-Gap für 1.0 **akzeptiert** +
> nginx-`proxy_next_upstream`-Weichmacher (echtes Zero-Downtime = post-1.0/G7) = **DECIDED** ·
> Q6 = **Variante A2** (`swr` + interner Nitro-Purge-Endpoint, BE macht `curl`) = **DECIDED**;
> Variante B verworfen (Backup, falls Purge-Risiko eskaliert). **Auflage zu A2:** Purge-Risiko
> **G15** (routeRules-Cache-Invalidierung ist Nitro-intern/undokumentiert, nuxt#20495) →
> Nitro-Version-Pin + Smoke-Test sind **Pflicht-Bestandteil von 1.0, nicht optional.**
> Status-Übersicht aller Q in §6, 1.0-Roadmap in §5, Umsetzungs-Reihenfolge in §7.
>
> **Anlass (Keystone-Entscheid Austin, 2026-06-10):** Das neue ValidSlots-Nuxt3-Frontend
> rendert via **Nitro-Server (SSR + SWR-Caching)**, NICHT Vollstatik `nuxi generate`.
> Deploy-Modell wechselt damit von „bauen + statisch ausliefern + Flag-File-Rebuild-Trigger"
> (capistrano-nuxt2) zu **„bauen + Node-Service durchstarten"**.
>
> Referenzen: `lib/capistrano/tasks/nuxt3.rake` (IST v0.5.0) ·
> `capistrano-nuxt2/lib/capistrano/tasks/nuxt.rake` (Alt-Schema) ·
> `capistrano-recipes2go/lib/capistrano/tasks/keys.rake` (`keys`-Muster) ·
> ValidSlots `slots_docs/FRONTEND_ARCHITECTURE.md` §2 + §5.2 (Konsument-Sicht).

---

## 1. Deploy-Ablauf für Nitro (SSR)

### 1.1 Der Happy Path (`cap <stage> deploy`, `nuxt3_deploy_mode = :ssr`)

```
deploy:starting … deploy:published          # Standard-Capistrano (releases/, current → release)
  └─ hook deploy:published → nuxt3:rebuild_app
       1. nuxt3:install_dependencies   # npm ci|install im Release   → State 'installing|deploy'
       2. nuxt3:build                  # nuxt build → .output/       → State 'building|deploy'
       3. nuxt3:sync_output            # rsync -a --delete
          #    release/.output/  →  shared/output/                   → State 'syncing|deploy'
          #    bei Erfolg: 'success|deploy' + touch _builded_frontend
       4. nuxt3:ssr:restart            # sudo systemctl restart <app>_<stage>_nuxt3_ssr
```

Der Nitro-Service läuft **aus `shared/output/`** (`node shared/output/server/index.mjs`),
nicht aus `current/` — bewusst: das Build-Artefakt überlebt Release-Rotation/`deploy:cleanup`,
und der Restart-Zeitpunkt ist vom Release-Symlink entkoppelt. nginx (bzw. der
`proxy_nginx`-Proxy-Host) zeigt per `nginx_upstream_host/port` auf `127.0.0.1:<nuxt3_ssr_port>`.

**Erst-Deploy** (Unit existiert noch nicht — analog puma/sidekiq in recipes2go):
`set :nuxt3_ssr_hooks, false` → `cap <stage> deploy` (baut + synct, kein Restart) →
`cap <stage> nuxt3:ssr:configure` (Unit hochladen + enable + start) → Flag zurück auf `true`.
*(Gap G4: das soll in 1.0 automatisch erkannt werden, s. §5.)*

### 1.2 Konsequenz des Modellwechsels

| | nuxt2 (Vollstatik) | recipes4nuxt SSR (NEU) |
|---|---|---|
| Artefakt | `dist/` → `shared/www/`, nginx serviert Files | `.output/` → `shared/output/`, Nitro-Prozess serviert |
| „Live schalten" | rsync ist der Go-Live | rsync **+ Service-Restart** ist der Go-Live |
| Content-Aktualität | eingefroren bis zum nächsten Render | **DECIDED A2:** `swr` zur Laufzeit (routeRules, TTL) — frisch ≤TTL automatisch, sofort bei Admin-Purge (§6a) |
| Admin-Rebuild-Trigger | Kern-Feature (Sidekiq-Worker, `npm run export`) | **bleibt funktionell**; Mittel = `curl` auf internen Nitro-Purge-Endpoint (DECIDED A2, §3.2 + §6a) |
| Laufzeit-Abhängigkeit | keine (nur nginx) | Node-Prozess muss überwacht laufen (s. §2) |

⚠️ Bewusster Trade-off (**Q5 — ✅ DECIDED 2026-06-11**): `systemctl restart` hat einen **kurzen
Downtime-Gap** (Sekunden, Nitro bootet schnell), und das `rsync --delete` in `shared/output/` tauscht
Dateien unter dem laufenden Prozess (der alte Prozess hält sein `index.mjs` offen — ESM ist beim Start
geladen, Assets unter `.output/public` könnten kurz mixen). Für **On-Prem mit 1 Instanz/Kunde**
**akzeptieren wir diesen Gap für 1.0** (Austin 2026-06-11).

**✅ Q5 DECIDED (Austin 2026-06-11): Restart-Gap für 1.0 akzeptiert + nginx-Weichmacher Pflicht.**
Der Gap wird für 1.0 in Kauf genommen, abgefedert durch den billigen Weichmacher:
nginx `proxy_next_upstream error timeout http_502` (+ `proxy_next_upstream_tries 2`), sodass ein
Request, der genau ins Restart-Fenster fällt, automatisch einen zweiten Versuch bekommt — bei
einem Sekunden-Restart fällt das real praktisch nie auf. **Echtes** Zero-Downtime
(Port-Flip: zwei Units A/B + nginx-Upstream-Switch, oder Socket-Activation) ist damit bewusst
**post-1.0 / Gap G7** und kein 1.0-Blocker.

**✅ Umgesetzt GEM-seitig (feat/ssr-1.0, 2026-06-11):** Der Weichmacher steht jetzt im
`templates/nginx_proxy_conf.erb` (im `location /`-Block), nicht mehr manuell pro App. Defaults
(zero-config, via `fetch(:..., default)` überschreibbar):

```ruby
set :nginx_proxy_next_upstream,         "error timeout http_502 http_503"  # Default
set :nginx_proxy_next_upstream_tries,   2                                  # Default
set :nginx_proxy_next_upstream_timeout, "5s"                               # Default
```

Die Bedingungen sind bewusst **idempotent/sicher** (connect-error, timeout, 502/503) — der
Request hat in diesen Fällen den App-Code nie erreicht, ein Retry kann also keinen Seiteneffekt
doppelt auslösen. Damit ist der Weichmacher **auch für den `:static`/Rails-Proxy-Fall harmlos**
(gleiches Template, gleiche idempotenten Bedingungen — kein Verhalten verschlechtert; konkret
**KEIN** `non_idempotent` und **KEIN** `http_500/http_504` in den Defaults). Leerstring/`nil` für
`:nginx_proxy_next_upstream` lässt den Block komplett weg (Opt-out).

### 1.3 Static-Mode bleibt

`set :nuxt3_deploy_mode, :static` (Content-Sites): `nuxi generate` → `shared/www/` → nginx,
**kein** Node-Service. Der Hook routet automatisch. Dieser Kontrakt hier beschreibt den
SSR-Pfad; der Static-Pfad behält das alte nuxt2-Verhalten 1:1 (inkl. Flag-File-Semantik).

---

## 2. Service-Management: PM2 vs. systemd → **DECIDED: systemd** (Q1, Austin 2026-06-11)

> ✅ **Q1 ENTSCHIEDEN (Austin 2026-06-11): systemd, PM2 raus.** Der untenstehende Vergleich
> ist die Begründung; v0.5.0-Implementierung (systemd-Unit-Template) wird bestätigt und ausgebaut.

| Kriterium | systemd | PM2 |
|---|---|---|
| Zusätzliche Abhängigkeit | keine (OS-Bestandteil) | global npm-Paket, eigene Daemon-Schicht, Versionspflege pro Kundenserver |
| Haus-Muster | **identisch zu recipes2go** (puma/sidekiq/thin laufen als systemd-Units, Monit-fähig via PIDFile) | Fremdkörper im Stack, zweiter Supervisor neben systemd |
| Crash-Recovery | `Restart=always` + `StartLimitBurst` (im Template vorhanden) | gleichwertig |
| Boot-Persistenz | `systemctl enable` (deklarativ) | `pm2 startup` + `pm2 save` (imperativ, generiert selbst wieder eine systemd-Unit…) |
| Logs | journald (`nuxt3:ssr:logs` = journalctl), kein Rotations-Setup nötig | eigene Logfiles + `pm2-logrotate` als Extra-Modul |
| Cluster/Reload | kein Cluster, Restart-Gap | Cluster-Mode + `pm2 reload` (zero-downtime) |
| Sudo-/Rechte-Modell | klar: Deploy-User + sudo systemctl (wie alle recipes2go-Services) | PM2-Daemon läuft als User, Status lebt in `~/.pm2` — fragiler bei mehreren Deploy-Usern |

**Begründung der Empfehlung:** PM2s einziger echter Vorteil — Cluster-Mode mit
Zero-Downtime-Reload — zieht bei **On-Prem mit genau 1 Instanz pro Kunde** nicht: keine
Lastverteilung nötig, und der Restart-Gap einer einzelnen Nitro-Instanz liegt im
Sekundenbereich. Dafür kostet PM2 eine zusätzliche globale Dependency auf jedem Kundenserver
(Drop-in-Update-Regel!), einen zweiten Supervisor-Layer und bricht das etablierte
recipes2go-Muster (systemd-Unit + PIDFile für Monit). Das vorhandene Template
`lib/generators/.../templates/nuxt3_ssr_service.erb` setzt genau das bereits um
(Unit pro App+Stage, `Environment=`-Zeilen, PIDFile, journald, nvm-aware ExecStart).

→ **v0.5.0-Implementierung (systemd) bestätigen und ausbauen, PM2 verwerfen.**

---

## 3. Flag-File-Schema: was bleibt, was entfällt

Alt-Schema (`capistrano-nuxt2/lib/capistrano/tasks/nuxt.rake` + ValidSlots-BE
`build_frontend_worker.rb` / `stuff_controller.rb`): drei `linked_files` in `shared/`,
Format `state|actor`, mtime = Zeitstempel.

### 3.1 BLEIBT — Deploy-Status-Sichtbarkeit (Lesekontrakt fürs Backend/Admin-UI)

| Datei | Semantik (SSR-Welt) | Wer schreibt |
|---|---|---|
| `_builded_app` | eine Zeile `<state>\|<actor>`; mtime = letzte Statusänderung | **nur noch `deploy`** |
| `_builded_logs` | Build-Log des letzten Deploys | deploy |
| `_builded_frontend` | leer; **mtime = letzter erfolgreicher Deploy** | deploy (`touch` bei Erfolg) |

States im SSR-Pfad (alle Akteur `deploy`, schreibt `nuxt3.rake` heute schon):
`installing` → `building` → `syncing` → `success`. *(Vorschlag 1.0: zusätzlich
`restarting|deploy` vor dem Service-Restart und `ERROR-<task>|deploy` im Fehlerfall,
damit die UI einen hängenden/kaputten Deploy unterscheiden kann — Gap G2.)*

Warum behalten: Das Admin-Dashboard (`renderState.vue`-Nachfolger) kann damit weiterhin
**„zuletzt deployed am … / Deploy läuft gerade (Schritt X)"** anzeigen — die
Deploy-Sichtbarkeit war im Alt-System ein geschätztes Feature („Seite wurde gerade via
Deployment neu gerendert") und kostet uns nichts: Dateien sind bereits `linked_files`,
`setup` legt sie an, die Schreiblogik existiert.

Die Semantik von `_builded_frontend` verschiebt sich von „letzter erfolgreicher **Render**"
zu „letzter erfolgreicher **Deploy**". Der `buildNeeded`-Vergleich des BE
(`max(updated_at)` vs. mtime) wird damit für Content **bedeutungslos** — Content ist via
SWR nach TTL-Ablauf automatisch frisch.

### 3.2 BLEIBT FUNKTIONELL — Admin-Rebuild-Trigger (Q2-Override + Q6=A2, ✅ DECIDED 2026-06-11)

> ✅ **DECIDED 2026-06-11.** Der alte §3.2 sagte „ENTFÄLLT ersatzlos" — das ist **überholt**.
> Austin 2026-06-11: *„admin trigger muss funktionell möglich, triggert aktuell einen sidekiq task
> der die seite neu rendert."* Der Admin-Trigger **bleibt als Funktion erhalten** (Q2), und das
> **Mittel ist jetzt entschieden: Variante A2** (`swr` + interner Nitro-Purge-Endpoint, BE macht
> `curl`) — voll ausgearbeitet in **§6a**. Variante B ist verworfen (Backup, falls das Purge-Risiko
> G15 eskaliert).

Was das konkret heißt (Variante A2):

- Der **Admin-Button** (heute `renderState.vue` → `$admin.index('rebuild_frontend')`) und der
  **BE-Endpoint** `GET rebuild_frontend` (heute `BuildFrontendWorker.perform_async`) bleiben.
  Nur die **Aktion** ändert sich: der Worker macht statt `npm run export` einen **authentifizierten
  `curl 127.0.0.1:<port>/api/_purge`** → der interne Nitro-Endpoint purged die Route-Caches
  (`useStorage('cache').clear('nitro:routeRules')`) → nächster Request rendert frisch. **Kein
  npm-Build.** (§6a, Variante A)
- Der **Flag-Datei-Status-Kontrakt** (§3.1, `_builded_app`/`_builded_logs`/`_builded_frontend`)
  bleibt der Lesekontrakt für die Admin-UI — die UI zeigt weiter „zuletzt aktualisiert / läuft
  gerade" und zusätzlich die **SWR-TTL** („Inhalte spätestens nach N Min frisch").
- **Akteur-States im SSR-Pfad:** `initialized|admin-interface` + `purging|admin-interface` kommen
  hinzu — der Akteur-Teil (`admin-interface` vs `deploy`) trennt weiterhin „Admin hat getriggert"
  von „Deployment lief". `generating|deploy` (npm-Re-Render) taucht im SSR-Pfad **nicht** auf
  (das wäre das verworfene Variante-B-Verhalten).

**Revier-Abgrenzung (A2):** recipes4nuxt liefert die **Deploy-/Task-Seite** (Tasks, Unit-Template);
der Purge-Endpoint lebt im **FE/Layer** (Luke / ggf. Tim-Layer, wiederverwendbar), der **Admin-Button
(FE)** ist **Luke-Revier**, der **BE-Endpoint/Worker** (`curl`-Call) ist **Bill-Revier** (slots).
Gem-Last in A2 ist gering. Genaue Slot-Schnitte in §6a, Variante A, Punkt (2).

---

## 4. ENV-Kontrakt pro On-Prem-Instanz

> ✅ **Q3 ENTSCHIEDEN (Austin 2026-06-11): ENV-File-Ansatz (§4.2) bestätigt.** → Gap G1 ist freigegeben.
> ✅ **Q4 ENTSCHIEDEN (Austin 2026-06-11): `NUXT_APP_ENV` ok** (§4.3 / G12). Austins Rückfrage
> „wenn mehrere auf einem Server?" ist in §4.4 geklärt.

### 4.1 Prinzip: ein Code-Stand → viele Instanzen, Werte zur **Laufzeit**

Nuxt 3 `runtimeConfig` liest beim **Prozess-Start** `NUXT_*`-ENV-Variablen:
`NUXT_PUBLIC_API_BASE` → `runtimeConfig.public.apiBase` usw. Anders als bei Nuxt 2
(Build-Zeit-Inlining via `env.API_URL`) braucht eine Instanz-Anpassung also **keinen
Rebuild, nur einen Service-Restart**. Pro Kunde unterscheiden sich nur ENV-Werte
(API-URL, Tenant-Name, Keys), nicht das Artefakt. *(Branding/Theme = `app.config.ts`,
Build-Zeit — bereits mit slots geklärt; hier geht es nur um die Laufzeit-Werte.)*

⚠️ **Zwei Einschränkungen ehrlich benannt:**
1. **Prerenderte Routen** backen die zur Build-Zeit sichtbaren Werte ins HTML — da
   Capistrano ohnehin **auf dem Kundenserver baut** (jede Instanz = eigener Build auf
   ihrem Host), ist das praktisch unkritisch, solange Build-ENV = Runtime-ENV (s. 4.3).
2. Client-Bundle-Hydration: `NUXT_PUBLIC_*` wird vom Server im Payload an den Client
   gereicht — funktioniert; nur **nie Secrets in `NUXT_PUBLIC_*`** legen (die gehören in
   server-only `runtimeConfig`, ENV ohne `PUBLIC`).

### 4.2 Wo die ENV-Files liegen — Vorschlag (analog recipes2go-`keys`)

recipes2go löst Instanz-Config fürs Rails-BE mit `keys:upload_config`: lokales
`config/configuration.yml` → rsync nach `shared/config/`, dort `linked_file`. **Dasselbe
Muster fürs FE**, nur als ENV-File statt YAML (systemd-nativ):

```
LOKAL (Konsum-App, NICHT committet, .gitignore):
  config/nuxt_env/<stage>.env          # eine Zeile pro Variable, KEY=value

SERVER:
  shared/config/nuxt3_ssr.env          # Ziel des Uploads, nur dort persistent
```

Systemd-Unit lädt es **zusätzlich** zu den statischen `Environment=`-Zeilen:

```ini
EnvironmentFile=-<shared_path>/config/nuxt3_ssr.env   # '-' = optional, zero-config-safe
```

Neue Tasks (Gap G1): `nuxt3:ssr:upload_env` (rsync wie `keys:upload_config`, eingehängt in
`setup` + optional `deploy:starting`) und `nuxt3:ssr:check_env` (warnt bei leer/fehlend,
wie `keys:check_keys`). Bestehendes `set :nuxt3_ssr_env, {…}` bleibt für **unkritische,
stage-statische** Werte (z. B. Port-Doku) — **Secrets/Kunden-Werte gehören ins ENV-File,
nicht ins Repo** (Deploy-Configs der Konsum-Apps = T4/Austin; das Gem gibt nur den
Mechanismus vor).

Rollenverteilung pro Variable (Konvention):

| Variable | Quelle | Beispiel |
|---|---|---|
| `NITRO_HOST` / `NITRO_PORT` / `NODE_ENV` | Unit-Template (aus `:nuxt3_ssr_host/_port`) | `127.0.0.1:3500` |
| `NUXT_PUBLIC_*` (Instanz-Werte, public) | `shared/config/nuxt3_ssr.env` | `NUXT_PUBLIC_API_BASE=https://api.kunde-x.ch` |
| server-only Secrets (`NUXT_*` ohne PUBLIC) | `shared/config/nuxt3_ssr.env` | `NUXT_ONEDOC_API_KEY=…` |
| Deploy-Mode-Var (s. 4.3) | `default_env` (Stage-File) | `NUXT_APP_ENV=production` |

### 4.3 Build-ENV = Runtime-ENV (eine Quelle)

Die Build-Tasks injizieren heute `fetch(:default_env)`; der Service bekommt Unit-ENV +
ENV-File. Damit prerenderte Seiten und Laufzeit nicht divergieren, gilt ab 1.0:
**die nuxt3-Build-Tasks sourcen zusätzlich `shared/config/nuxt3_ssr.env`** (per
`set -a; . <file>; set +a` im `bash -lc`-Wrapper) — eine Quelle, kein Drift (Gap G3).
Die alte `nuxt_stage_env_var`-Mechanik (`APP_NAME_STG_DEPLOY_MODE`, im Code selbst als
„Maybe nonsense" markiert) wird durch eine **neutrale** Variable ersetzt: ✅ **`NUXT_APP_ENV=<stage>`
via `default_env`** (Q4 DECIDED — deckt auch ValidSlots' De-Brand-Wunsch `SLOTS_DEPLOY_MODE`
generisch ab; ValidSlots mappt seinen `SLOTS_DEPLOY_MODE`-Switch in `nuxt.config.ts` darauf).

### 4.4 Mehrere SSR-Instanzen auf EINER Box — was kollidiert, was nicht (Q4-Klärung)

Austins Rückfrage zu Q4 („wenn mehrere auf einem Server?"): Die meisten Kontrakt-Bausteine
sind **schon pro Instanz eindeutig** und kollidieren nicht bei Mehrfach-Belegung einer geteilten
Box:

| Baustein | Schema | Kollidiert bei N Instanzen? |
|---|---|---|
| systemd-Service-Name | `{application}_{stage}_nuxt3_ssr` | **nein** — app+stage macht ihn eindeutig |
| ENV-File-Pfad | `{deploy_to(app,stage)}/shared/config/nuxt3_ssr.env` | **nein** — eigener `shared/`-Baum pro Instanz |
| `NUXT_APP_ENV` | `<stage>` | **nein** — reine Stage-Kennung, darf sich wiederholen |
| nginx `server_name` / Upstream | per App/Domain | **nein** — ohnehin pro App konfiguriert |
| **`nuxt3_ssr_port`** | `127.0.0.1:<port>` | ⚠️ **JA** — der EINZIGE Wert, der **pro Instanz auf einer geteilten Box eindeutig** sein muss |

→ **Pflicht-Hinweis (Konsum-App):** Bei mehreren SSR-Apps auf einem Host muss
`set :nuxt3_ssr_port, <wert>` pro App/Stage **eindeutig** vergeben werden (zusammen mit dem
passenden nginx-Upstream). Zwei Instanzen auf demselben Port → die zweite Unit startet nicht
(`EADDRINUSE`).

### 4.5 Bind-Host: Single-Host vs. Cross-Host-Proxy (G16, ⚠️ Firewall-Pflicht)

> ✅ **Umgesetzt GEM-seitig (feat/ssr-1.0, 2026-06-11, Cargo).** Aufgedeckt vom moja-Testbett
> (Robert): moja deployt im **Cross-Host-Proxy-Setup** — öffentlicher Proxy-LXC proxyt auf eine
> **andere** App-LXC (Nitro). Der bisherige Default `nuxt3_ssr_host = 127.0.0.1` ist dort
> cross-host **unerreichbar**.

Nitro bindet `NITRO_HOST`/`HOST` = `fetch(:nuxt3_ssr_host)`. Es gibt **zwei Topologien**:

| Topologie | Wer ist der Proxy | `:nuxt3_ssr_host` | Begründung |
|---|---|---|---|
| **Single-Host** | Proxy + App auf **derselben** Box | **`127.0.0.1`** (Default — NICHT ändern) | Proxy erreicht Nitro über Loopback; sicherster Default, Port nie im LAN sichtbar |
| **Cross-Host** | Proxy auf **anderer** Box (recipes2go/`proxy_nginx`-Muster) | **`0.0.0.0`** (oder die App-LAN-IP) | Loopback ist von der Proxy-Box nicht erreichbar → Nitro muss auf allen Interfaces (bzw. der LAN-IP) lauschen |

```ruby
# Cross-Host-Setup (Proxy auf anderer Box):
set :nuxt3_ssr_host, "0.0.0.0"     # Nitro auf allen Interfaces
# (Single-Host: nichts setzen → bleibt 127.0.0.1)
```

⚠️ **SICHERHEITS-AUFLAGE (Pflicht, wenn `nuxt3_ssr_host = 0.0.0.0`):** Lauscht Nitro auf
`0.0.0.0`, ist der **rohe Node-Prozess offen im LAN** — anders als bei recipes2go puma/thin gibt
es **keinen App-Nginx vor Nitro** (dort fronten App-Nginx + unix-Socket den App-Prozess, hier
spricht der Proxy direkt mit dem Nitro-TCP-Port). Die App-LXC **MUSS** daher den SSR-Port
(`:nuxt3_ssr_port`, Default 3500) per **quell-beschränkter Firewall-Regel** auf die **Proxy-IP /
das Tailnet** beschränken — öffentlich/LAN bleibt dicht:

```sh
# Auf der App-LXC, einmalig, vom Infra-Verantwortlichen (siehe T4-Hinweis unten):
ufw allow from <proxy-tailnet-ip> to any port <nuxt3_ssr_port> proto tcp
```

> 🔒 **Das ist ein T4-Infra-Schritt (Austin), KEIN per-Deploy-Capistrano-Task.** Begründung:
> - **NICHT** `ufw allow <port>` / **NICHT** `set :ufw_additional_ports, [3500]` verwenden — beides
>   macht ein nacktes `ufw allow <port>`, das den Port **öffentlich für ALLE** (LAN + extern) öffnet.
>   Das ist das **Gegenteil** der Auflage: Nitro auf `0.0.0.0` **plus** Port offen = der Node-Prozess
>   ist exponiert.
> - recipes2gos `ufw`-Recipe (`lib/capistrano/tasks/ufw.rake`) kann **nur** `ufw allow <port>` und
>   **keine quell-beschränkten** Regeln (`from <ip>`) — es kann die Auflage also gar nicht korrekt
>   umsetzen. Zusätzlich macht sein `ufw:setup` ein `ufw --force reset`, das eine manuell gesetzte
>   `from`-Regel beim nächsten Lauf wieder **wegräumt**.
> - **recipes4nuxt hat bewusst KEIN ufw-Recipe.** Eine security-sensitive Firewall-Regel gehört nach
>   T4/Infra (Austin), nicht in eine Gem-Automatik — analog zu „Deploy-Configs/Secrets ≠ Repo".

> **Künftiger Gap (NICHT jetzt bauen):** Ob recipes4nuxt perspektivisch einen *quell-beschränkten*
> Firewall-Helfer bekommen soll (z. B. einen Task, der `ufw allow from <proxy-ip> to any port <port>
> proto tcp` setzt, idempotent + reset-fest), ist offen. **Default-Haltung: Firewall bleibt T4/Infra
> (Austin)** — eine security-sensitive Regel über Gem-Automatik auszurollen birgt mehr Risiko als
> Nutzen (falsche IP / `--force reset`-Wechselwirkungen / Lock-out). Erst bauen, wenn ein konkreter
> Bedarf das rechtfertigt und Austin es freigibt.

> **Health-Check entkoppelt (G16):** `nuxt3:ssr:verify` curlt nicht den Bind-Host, sondern den
> separaten **`:nuxt3_ssr_healthcheck_host`** (Default `127.0.0.1`). Der Check läuft **lokal auf
> der App-Box**, daher ist Loopback dort immer korrekt — auch wenn Nitro auf `0.0.0.0` bindet
> (ein Client-`curl` auf `0.0.0.0` ist unportabel/undefiniert; deshalb der dedizierte
> Loopback-Default statt Wiederverwendung des Bind-Hosts). Kein Override nötig im Normalfall.

**Vorschlag (Gap G13, nicht implementieren):** ein optionaler Doppelbelegungs-Check
`nuxt3:ssr:check_port` — vor `ssr:configure`/`restart` prüfen, ob `<port>` bereits von einer
**fremden** Unit belegt ist (z. B. `ss -ltnp 'sport = :<port>'` bzw. Abgleich der vorhandenen
`*_nuxt3_ssr.service`-EnvironmentFiles auf denselben `NITRO_PORT`), und mit klarer Meldung
abbrechen statt mit `EADDRINUSE` im journal zu enden. Reiner Ergonomie-Guard, blockt nichts
Bestehendes (zero-config-safe).

---

## 5. Gap-Liste = verbindliche 1.0-Roadmap (v0.5.0 → „SSR vollständig")

> Diese Tabelle ist nach den Entscheiden vom 2026-06-11 die **verbindliche 1.0-Roadmap**.
> Spalte **A2?** markiert die Variante-A2-spezifischen Punkte (Content-Refresh + Purge).
> Prio-Buckets: **P0** = 1.0-Blocker (muss rein) · **P1** = 1.0-Soll (nach Tim-Priorisierung) ·
> **P2** = post-1.0 erlaubt.

| # | Gap | Prio | A2? | Aufwand |
|---|---|---|---|---|
| G1 | **ENV-File-Kontrakt**: `EnvironmentFile=-…/nuxt3_ssr.env` ins Unit-Template + Tasks `nuxt3:ssr:upload_env` / `check_env` (keys-Muster, §4.2) — **✅ Etappe 1 gebaut (feat/ssr-1.0)** | **P0** | | M |
| G2 | **Flag-File-Vervollständigung SSR**: States `restarting\|deploy`, `purging\|admin-interface`; `ERROR-<task>\|deploy` bei Task-Fehlschlag (Fehler-Sichtbarkeit in der Admin-UI) — **✅ Etappe 1 gebaut (feat/ssr-1.0)** (`restarting`+`ERROR-<task>`+`success`-Neuverortung; `purging\|admin-interface` = Etappe 2/A2) | **P0** | (Teil) | S |
| G3 | **Build-Logs + Build-ENV**: `nuxt build` loggt heute NICHT nach `_builded_logs` (nur `generate`, und auch dort fehlt das `tee` im nvm-Zweig — Bug); Build-Tasks sourcen das ENV-File (§4.3) — **✅ Etappe 1 gebaut (feat/ssr-1.0)** | **P0** | | S–M |
| G4 | **Erst-Deploy-Ergonomie**: Hook prüft `systemctl cat <unit>` — Unit fehlt → automatisch `ssr:configure` statt Restart; `nuxt3_ssr_hooks=false`-Tanz entfällt — **✅ Etappe 1 gebaut (feat/ssr-1.0)** | **P0** | | S |
| G5 | **Health-Check** `nuxt3:ssr:verify` nach Restart (curl `127.0.0.1:<port>` mit Retry, Deploy schlägt fehl statt still kaputt); ans Hook-Ende — **✅ Etappe 1 gebaut (feat/ssr-1.0)** | **P0** | | S |
| G14 | **Content-Refresh-Mechanik (A2)**: FE-seitig interner Purge-Endpoint + `swr`-routeRules (FE/Layer-Revier); Gem-Seite klein — Purge-Konvention dokumentieren, ENV/Port-Kontrakt für den Endpoint sichern (kein Cache-Driver-Mount nötig, da A2 prozess-intern). Blockt den slots-Admin-Trigger. | **P0** | **✅ A2** | M (klein gem-seitig) |
| G15 | **Purge-Smoke-Test + Nitro-Version-Pin (A2-Auflage, Austin 2026-06-11)**: routeRules-`swr`-Cache hat **kein First-Class-Invalidierungs-API** (nuxt#20495); Purge über Storage-Key-Prefix `nitro:routeRules` ist **internes/undokumentiertes** Verhalten → **Pflicht:** Pin auf getestete Nitro-Version **+** Smoke-Test, der den Purge real verifiziert. **Nicht optional** — Bestandteil der 1.0-Freigabe. | **P0** | **✅ A2** | S–M |
| G16 | **Cross-Host-Bind + Firewall-Auflage (§4.5, moja-Testbett Robert 2026-06-11)**: Cross-Host-Proxy-Setup braucht `nuxt3_ssr_host=0.0.0.0` (Single-Host bleibt 127.0.0.1); ⚠️ **Pflicht: quell-beschränkte Firewall-Regel** des SSR-Ports auf Proxy/Tailnet (`ufw allow from <proxy-ip> to any port <port> proto tcp`), da kein App-Nginx vor Nitro — **NICHT** `ufw allow <port>`/`ufw_additional_ports` (öffnet öffentlich); recipes2go-`ufw` kann keine Quell-Beschränkung, recipes4nuxt hat bewusst kein ufw → **T4-Infra-Schritt (Austin), kein per-Deploy-Task**. Health-Check über separaten `:nuxt3_ssr_healthcheck_host` (Default 127.0.0.1) vom Bind-Host entkoppelt. **✅ Gem-Teil gebaut (feat/ssr-1.0)** — Doku/Defaults/verify; die quell-beschränkte Firewall-Regel ist T4-Infra (Austin). | **P0** | | S |
| G9 | **Tests (Dexter)**: Specs für Task-Verkabelung + ERB-Template-Rendering (Unit-File mit/ohne ENV-File, nvm an/aus) | **P1** | | M |
| G10 | **Docs (Homer)**: README-SSR-Abschnitt mit diesem Kontrakt abgleichen; Migrations-Guide nuxt2→recipes4nuxt (inkl. „Worker → `curl`-Purge umbauen") | **P1** | (Teil) | S |
| G6 | **Monit-Pairing**: Monit-Template für die Nitro-Unit (PIDFile existiert schon), analog recipes2go `monit.rake` | **P1** | | M |
| G11 | **Scope-Entscheid Alt-Tasks**: `nuxt.rake` (Nuxt2) + `vue.rake` carry-over — in 1.0 behalten (Migrationspfad) oder deprecaten? | **P1** | | S |
| G12 | **Neutrale Deploy-Mode-Var** (`NUXT_APP_ENV` statt `build_deploy_env_var`-Konstrukt), abwärtskompatibel (Drop-in-Update-Regel!) — ✅ Q4 DECIDED, nur noch umsetzen | **P1** | | S |
| G7 | **Zero-Downtime** (echtes): Restart-Gap + `rsync --delete` unter laufendem Prozess (§1.2); Option Port-Flip (zwei Units A/B + nginx-Upstream-Switch) oder Socket-Activation. ✅ Q5 DECIDED: **post-1.0**, 1.0 nutzt nginx-`proxy_next_upstream`-Weichmacher. | **P2** | | L |
| G8 | **`node_modules`-Hygiene**: `rm -rf node_modules/*` + shared bei jedem Deploy = teuer; npm-Cache-Strategie prüfen (npm ci ist schon drin) | **P2** | | M |
| G13 | **Port-Doppelbelegungs-Check** `nuxt3:ssr:check_port` (§4.4): warnt bei `<port>`-Kollision auf geteilter Box statt `EADDRINUSE` im journal; reiner Ergonomie-Guard | **P2** | | S |

### Definition „1.0 = fertig" (verbindlich, Tim/Austin 2026-06-11)

**1.0 ist erreicht, wenn ALLE folgenden Bedingungen erfüllt sind:**

1. **Alle P0-Gaps umgesetzt:** G1, G2, G3, G4, G5, **G16** (Kern-SSR-Deploy inkl. Cross-Host-Bind +
   Firewall-Auflage) **+ G14 + G15** (Content-Refresh A2 inkl. der **Pflicht-Auflage**
   Nitro-Version-Pin + Purge-Smoke-Test — nicht optional).
2. **P1-Gaps** (G9, G10, G6, G11, G12) nach Tim-Priorisierung grün; mindestens G9 (Tests) + G10 (Docs).
3. **P2-Gaps** (G7, G8, G13) dürfen post-1.0.
4. **Freigabe-Bedingung (Tim/Austin, hart):**
   **(a) Voll-Parität zu `capistrano-nuxt2`** — alles, was der nuxt2-Recipe konnte (inkl. Deploy-Status-
   Sichtbarkeit + funktionaler Admin-Trigger), funktioniert im recipes4nuxt-SSR-Pfad gleichwertig.
   **(b) Ein realer, verifizierter Deploy** auf einem Testbett (moja- und/oder ValidSlots) ist
   nachweislich grün durchgelaufen (Build → Restart → Health-Check → Admin-Purge verifiziert).
   **→ Vor Erfüllung von (a) UND (b) erfolgt KEINE WIP-Entsperrung / kein 1.0-Release.**

---

## 6. Entscheidungs-Status — alle 6 Fragen DECIDED (Stand 2026-06-11)

> ✅ **Alle 6 offenen Fragen sind entschieden (Austin via Tim, 2026-06-11).** Es stehen keine
> Kontrakt-Entscheide mehr aus — was bleibt, ist die Umsetzung (blockiert bis WIP-Entsperrung).

| # | Frage | Entscheid (Stand 2026-06-11) |
|---|---|---|
| Q1 | **systemd vs PM2** (§2) | ✅ **DECIDED: systemd, PM2 raus** |
| Q2 | Admin-Rebuild-Trigger streichen? | ✅ **DECIDED: Trigger BLEIBT funktionell** (Override §3.2); Mittel = A2 (s. Q6) |
| Q3 | **ENV-File-Konvention** lokal `config/nuxt_env/<stage>.env` (gitignored) → `shared/config/nuxt3_ssr.env` | ✅ **DECIDED: ja** → G1 frei |
| Q4 | **Neutrale Deploy-Mode-Variable** `NUXT_APP_ENV` + Mehrfach-Instanz-/Port-Regel | ✅ **DECIDED: `NUXT_APP_ENV` ok**; Port-Regel geklärt (§4.4 — nur `nuxt3_ssr_port` muss pro Box eindeutig sein) |
| Q5 | **Zero-Downtime**: Sekunden-Restart-Gap für On-Prem 1.0 akzeptiert (G7 = post-1.0)? | ✅ **DECIDED: Gap für 1.0 akzeptiert** + nginx `proxy_next_upstream`-Weichmacher Pflicht; echtes Zero-Downtime = post-1.0/G7 (§1.2) |
| Q6 | **Content-Refresh-Mittel: Variante A (swr + Purge) vs B (prerender + Rebuild)?** | ✅ **DECIDED: Variante A2** (`swr` + interner Nitro-Purge-Endpoint, BE macht `curl`). **Variante B verworfen** (Backup, falls Purge-Risiko G15 eskaliert). **Auflage:** G15 (Nitro-Version-Pin + Purge-Smoke-Test) ist Pflicht-Bestandteil von 1.0 (§6a) |

---

## 6a. Content-Refresh — ✅ DECIDED: Variante A2 (Q6 + Q2)

> ✅ **ENTSCHIEDEN (Austin 2026-06-11): Variante A2** — `swr` + interner Nitro-Purge-Endpoint,
> BE macht `curl`. **Variante B ist verworfen** und bleibt hier nur als dokumentierter **Backup**
> stehen, falls das Purge-Risiko (G15) später eskaliert. Der Variantenvergleich unten ist die
> Entscheidungs-Grundlage; die Auflage zu A2 (Nitro-Version-Pin + Purge-Smoke-Test, G15) ist
> **Pflicht-Bestandteil von 1.0**.
>
> **Worum es geht:** Der Admin-Rebuild-Trigger **bleibt** (Q2-Override, §3.2). Der Admin drückt
> denselben Button und die Flag-Status-UI funktioniert weiter — das gewählte **Mittel** (A2):
> der Button purged via `curl` die Nitro-Route-Caches, der nächste Request rendert frisch.
> Heute (Nuxt2-Ist):
> Admin-Button → `GET rebuild_frontend` → Sidekiq `BuildFrontendWorker` → `npm run export`
> (= `nuxi generate`) → `rsync dist/ → shared/www/` → nginx serviert statisch. Debounce: 6-min-Fenster.
> Quelle Ist-Pfad: `slots_backend/app/workers/build_frontend_worker.rb`,
> `…/controllers/api/admin/stuff_controller.rb#rebuild_frontend`, `slots_nuxt2/components/api/renderState.vue`.

### 6a.0 Gemeinsame Basis (beide Varianten)

- **Marketing/Content-Routen** (`/`, `/labs/**`, `/analyse/**`, `[slug]`): das sind die Routen, um
  die es geht. **Buchungskalender bleibt `<ClientOnly>`/live** (nie Cache) — unverändert, betrifft
  keine Variante. **Admin/backend/client/payment/staff** = `ssr:false` SPA — unverändert.
- **Flag-Status-Kontrakt (§3.1) bleibt** Lesekontrakt der Admin-UI (`renderState`-Nachfolger).
- Der **Buchungs-/Slot-Datenpfad ist nie betroffen** — beide Varianten cachen nur redaktionellen Content.

---

### Variante A — `swr` + Cache-Purge-Trigger  *(✅ GEWÄHLT — A2)*

**Idee:** Content-Routen auf `swr` (stale-while-revalidate). Die TTL hält Inhalte im Normalbetrieb
von selbst frisch — **kein Rebuild**. Der Admin-Button löst keinen Build aus, sondern **purged
gezielt die Nitro-Route-Caches**; der nächste Request rendert sofort frisch (live aus dem Rails-BE).

**(1) routeRules-Beispiel** (`slots_frontend/nuxt.config.ts`):
```ts
routeRules: {
  '/':            { swr: 600 },   // 10 min; war prerender:true
  '/labs/**':     { swr: 600 },
  '/analyse/**':  { swr: 600 },
  '/[slug]':      { swr: 600 },
  // Buchung: Hülle gerendert, Kalender <ClientOnly> → kein Cache nötig
  '/admin/**':    { ssr: false }, '/backend/**': { ssr: false },
  '/client/**':   { ssr: false }, '/payment/**': { ssr: false }, '/staff/**': { ssr: false },
}
```
Mit `swr: 600` liefert Nitro eine gecachte Antwort sofort und revalidiert ≤10 min später im
Hintergrund. **Ohne** Admin-Purge ist Content also **spätestens nach TTL** frisch; **mit** Purge **sofort**.

**Die zentrale Mechanik-Recherche — wie purged man einen routeRules-`swr`-Cache gezielt?**

Belegt aus Nitro/Nuxt-Doku + Issues (Quellen unten):
- routeRules-`swr`/`cache` schreibt in die **`cache`**-Storage-Mount unter der Gruppe
  **`nitro/route-rules`** (cachedEventHandler/-Function nutzen `nitro/functions` bzw. `nitro/handlers`).
  Key-Schema `${base}:${group}:${name}:${getKey}.json`, Doppelpunkt-normalisiert.
- **Purge per Storage-Prefix** ist möglich:
  `await useStorage('cache').clear('nitro:routeRules')` (bzw. gezielt `removeItem(<key>)`).
  Gleiche Mechanik, mit der man `cachedEventHandler` über `clear('nitro:handlers')` leert.
- ⚠️ **RISIKO / ehrlich benannt:** Es gibt **KEIN First-Class-, offiziell-dokumentiertes
  Invalidierungs-API für routeRules-Caches.** Das `.invalidate()`-API existiert nur für
  `defineCachedFunction`/`defineCachedEventHandler`, **nicht** für routeRules. Der Storage-Prefix-Purge
  funktioniert, ist aber **internes/undokumentiertes** Verhalten (nuxt#20495: „no way to clear or
  bypass routeRules cache"). → Pin auf getestete Nitro-Version + Smoke-Test (Gap **G15**).
- ⚠️ **Cross-Prozess-Constraint (architektur-entscheidend):** Der Admin-Trigger läuft im **Rails/Sidekiq-Prozess**,
  der Nitro-Cache lebt im **Nitro-Prozess**. Beim **Default Memory-Driver kann ein Fremdprozess den
  Cache NICHT leeren.** Genau zwei saubere Wege:
  - **A1 — gemeinsamer Cache-Storage-Driver:** `cache`-Mount auf **fs** (`shared/`-Pfad) oder **redis**
    legen; dann kann der BE-Worker per `unstorage`/CLI die Keys mit Prefix `nitro:routeRules` löschen.
  - **A2 — interner Purge-Endpoint im Nitro:** ein geschützter `server/api/_purge`-Handler ruft
    `useStorage('cache').clear('nitro:routeRules')`; der BE-Worker macht nur einen authentifizierten
    `curl 127.0.0.1:<port>/api/_purge`. **Empfohlener Weg** — robust, driver-agnostisch, kein
    geteilter Storage nötig, Admin-Trigger = ein HTTP-Call.

  → **Fazit Recherche: Ja, der Purge geht — aber nur über A1/A2, nicht „out of the box".** Der
  saubere, empfohlene Pfad ist **A2 (interner Endpoint)**.

**(2) Revier-Abgrenzung Variante A:**
| Baustein | Wer |
|---|---|
| routeRules `swr` setzen | **Luke (slots-FE)** |
| `server/api/_purge`-Endpoint (A2) im FE/Layer + Auth-Token | **Luke (FE) / ggf. Tim-Layer** (wiederverwendbar) |
| `BuildFrontendWorker` → statt `npm run export` einen `curl …/_purge` (bzw. Storage-clear bei A1) | **Bill (slots-BE)** |
| Admin-Button + renderState-Texte („Inhalte spätestens nach N Min / jetzt aktualisiert") | **Luke (FE)** |
| recipes4nuxt: **Cache-Storage-Driver-Vorgabe** (fs/redis-Mount) im Unit/ENV-Kontrakt **falls A1**; bei A2 **nichts** (Endpoint lebt im FE) — optional Doku/Konvention | **Cargo (Gem)** — klein |

→ **Gem-Last in Variante A ist gering** (Kern liegt FE/BE-seitig). Bei A2 muss das Gem fast nichts
beisteuern; bei A1 die Driver-/Mount-Konvention (Gap G14-A).

**(3) BE/FE-Umbau-Aufwand (grobe Hausnummer):**
- **FE (Luke):** routeRules `prerender→swr` umstellen (~½ h) + Purge-Endpoint A2 schreiben (~½ Tag inkl.
  Auth). Hausnummer **~0,5–1 Tag.**
- **BE (Bill):** Worker-Innenleben tauschen (`npm run export`+rsync → ein `curl`-Call), Debounce/Flag-Logik
  bleibt fast 1:1. Hausnummer **~0,5 Tag.**
- **Gesamt ~1–1,5 Tag** + G15-Smoke-Test.

**(4) Betriebsverhalten:**
- **Frische:** ohne Klick ≤ TTL; mit Klick sofort. Kalender immer live.
- **Last:** minimal — Purge ist O(Cache-Keys löschen), Re-Render passiert lazy beim nächsten Request
  (ein SSR-Render, kein npm-Build). Skaliert auf häufige Edits.
- **Failure-Modes:** (a) Purge-Endpoint down → Content bleibt bis TTL stale (graceful, nicht kaputt).
  (b) Nitro-Update ändert internen Cache-Key/Prefix → Purge trifft ins Leere (G15-Risiko, durch
  Version-Pin + Smoke-Test abgefangen). (c) Memory-Driver versehentlich → A2 immun (Endpoint läuft
  im selben Prozess), A1 würde brechen → **A2 wählen.**

**(5) Neue Gaps:** **G14-A** (optionale Cache-Driver-/Mount-Doku, nur bei A1) · **G15**
(routeRules-Purge-Pfad ist undokumentiert → Smoke-Test + Version-Pin). Beide klein.

---

### Variante B — `prerender` + Rebuild-Trigger  *(❌ VERWORFEN — Backup, falls G15 eskaliert)*

> ❌ **Verworfen (Austin 2026-06-11).** Nicht für 1.0 umsetzen. Dokumentiert als Rückfall-Option,
> falls das routeRules-Purge-Risiko (G15) in der Praxis als No-Go eskaliert. Inhalt unverändert
> als Referenz.

**Idee:** Marketing-Routen bleiben `prerender: true` (zur Build-Zeit gerendert, danach
**eingefroren bis zum nächsten Rebuild**). Der Admin-Button triggert einen **echten Re-Render**
der prerender-Routen — konzeptionell exakt das heutige Nuxt2-Verhalten, nur mit Nitro-Build statt
`nuxi generate`.

**(1) routeRules-Beispiel:**
```ts
routeRules: {
  '/':            { prerender: true },
  '/labs/**':     { prerender: true },
  '/analyse/**':  { prerender: true },
  '/[slug]':      { prerender: true },
  '/admin/**':    { ssr: false }, /* … wie oben … */
}
```
⚠️ **Recherche-Befund:** Eine `prerender:true`-Route ist auf self-hosted Node **bis zum nächsten
Build eingefroren** — Nitro re-prerendert sie **nicht** zur Laufzeit. „Re-Render auslösen" heißt
daher zwingend **den Build-/Prerender-Schritt erneut fahren** (`nuxi build` mit Prerender-Pass).
*(Anmerkung: Nitros `isr`-routeRule wäre die „on-demand"-Mittellösung, verhält sich auf Node aber
wie `swr` und teilt dessen Purge-Problem — gehört damit konzeptionell zu Variante A, nicht B.)*

**(2) Verkabelung deploy-/task-seitig:**
- recipes4nuxt liefert einen Task **`nuxt3:rebuild`** (Vorschlag): `nuxi build` im `current/`
  (Prerender inklusive) → `rsync .output/ → shared/output/` → `systemctl restart …_nuxt3_ssr` →
  Flag-States schreiben (`rendering|admin-interface` → `success|admin-interface`).
- Der **BE-Worker triggert diesen Task** — zwei Wege:
  - **B1:** Worker macht **SSH auf den FE-Host** und ruft den cap-Task / direkt `nuxi build`
    (näher am Ist: Worker shellt heute schon `cd current && nvm use && npm run export`). Einfach,
    aber Worker braucht SSH-Recht + nvm-Umgebung am FE-Host.
  - **B2:** Worker stößt über Capistrano `cap <stage> nuxt3:rebuild` an (sauberer, aber cap muss
    vom BE-Host aus lauffähig sein).

**(3) Revier-Abgrenzung Variante B:**
| Baustein | Wer |
|---|---|
| `nuxt3:rebuild`-Task (build + sync + restart + Flag-States) | **Cargo (Gem)** — **substanziell** |
| routeRules `prerender` setzen | **Luke (FE)** |
| `BuildFrontendWorker` → Task/SSH-Trigger statt `npm run export` (Pfad-/nvm-/SSH-Verkabelung) | **Bill (BE)** |
| Admin-Button + renderState (bleibt fast 1:1 wie heute) | **Luke (FE)** — gering |

→ **Gem-Last in Variante B ist hoch** (der Rebuild-Task ist Kern-Gem-Arbeit).

**(4) BE/FE-Umbau-Aufwand (grobe Hausnummer):**
- **Gem (Cargo):** `nuxt3:rebuild`-Task neu, sauber mit Flag-States + Restart-Verkabelung **~1 Tag.**
- **BE (Bill):** Worker auf Task/SSH-Trigger umbauen, SSH-/nvm-Umgebung absichern **~0,5–1 Tag.**
- **FE (Luke):** routeRules `prerender` (~½ h), UI bleibt ~gleich. **~½ Tag.**
- **Gesamt ~2–2,5 Tag.**

**(5) Betriebsverhalten:**
- **Frische:** nur nach Trigger (oder Deploy). Edit ohne Klick → Seite bleibt alt (= heutiges Verhalten,
  Admin kennt das).
- **Last:** **hoch pro Trigger** — jeder Klick = voller `nuxi build` + Prerender + Restart
  (Sekunden–Minuten je nach Seitenzahl, CPU-Spike, Restart-Gap je Trigger). Debounce-Fenster bleibt nötig.
- **Failure-Modes:** Build schlägt fehl → `ERROR-<code>` (wie heute, gut sichtbar). Build-Last auf der
  Kunden-Box bei häufigen Edits. Restart-Gap (§1.2/Q5) bei **jedem** Trigger, nicht nur beim Deploy.

**(6) Neue Gaps:** **G14-B** (`nuxt3:rebuild`-Task + Trigger-Verkabelung BE↔FE, inkl. SSH/cap-Pfad) —
mittel–groß, plus Re-Render-States im Flag-Schema.

---

### 6a.x Entscheidungs-Tabelle A vs B

| Kriterium | **A — swr + Purge** | **B — prerender + Rebuild** |
|---|---|---|
| Content-Frische ohne Klick | ≤ TTL automatisch frisch | eingefroren bis Trigger/Deploy |
| Content-Frische mit Klick | **sofort** (lazy Re-Render) | nach Build (Sek.–Min.) |
| Last pro Admin-Klick | **minimal** (Cache-Keys löschen) | **hoch** (voller npm-Build + Restart) |
| Nähe zum heutigen Ist | mittel (neues Konzept) | **hoch** (≈ `npm run export`-Pfad) |
| Gem-Aufwand (Cargo) | **gering** (A2: ~nichts; A1: Driver-Doku) | **hoch** (`nuxt3:rebuild`-Task) |
| BE+FE-Aufwand | **~1–1,5 Tag** | ~2–2,5 Tag |
| Restart-Gap (Q5) | nur beim Deploy | bei **jedem** Trigger |
| Technisches Risiko | ⚠️ routeRules-Purge undokumentiert (G15) | gering (Build ist Standard) |
| Failure-Mode | graceful (stale bis TTL) | Build-Fehler sichtbar, Box-Last |
| Skaliert bei häufigen Edits | **ja** | nein (Build-Last) |

### 6a.y Entscheid + Begründung (✅ A2 GEWÄHLT, Austin 2026-06-11)

**→ ✅ GEWÄHLT: Variante A2 (swr + interner Purge-Endpoint) — mit verbindlicher Risiko-Auflage.**

Begründung (= Cargo-Votum, von Austin bestätigt): A ist betrieblich klar überlegen — sofortige
Frische bei minimaler Last, graceful bei Fehlern, skaliert bei häufigen Content-Edits, kein
Restart-Gap pro Klick, und die Gem-Last ist klein (Kern liegt sauber in FE/BE-Slots). Der
entscheidende Vorbehalt ist **G15**: routeRules-Cache-Purge hat **kein offizielles API**; der
Storage-Prefix-Purge ist internes Verhalten. Das ist entschärft durch **A2 (interner Purge-Endpoint
statt Fremdprozess-Storage-Zugriff)** + **Nitro-Version-Pin + Purge-Smoke-Test** — beides ist als
**Pflicht-Auflage** (G15, P0) in der 1.0-Roadmap verankert, nicht optional. Damit ist das Restrisiko
ein Versions-Upgrade-Check, kein Architektur-Problem.

**Verworfen: Variante B** — bleibt dokumentierter Backup. Falls das undokumentierte Purge-Verhalten
in der Praxis doch als No-Go eskaliert, ist B der sichere, aber teurere Rückfall (Standard-Build,
kein API-Risiko; Preis: mehr Gem-Arbeit, Build-Last + Restart-Gap pro Klick, eingefrorener Content
zwischen Klicks). Beide hielten den Admin-Trigger funktionell (Q2 erfüllt) — entschieden ist A2.

### 6a.z Quellen (Nitro/Nuxt-Mechanik, geprüft)

- Nitro Cache-Doku — Storage-Mount `cache`, Key-Schema `${base}:${group}:${name}:${getKey}.json`,
  Gruppen `nitro/functions` · `nitro/handlers` · `nitro/route-rules`, Driver-Config (`storage.cache`):
  https://nitro.build/docs/cache
- nuxt/nuxt Discussion #20495 — „**no way to clear or bypass routeRules cache**" (kein First-Class-API):
  https://github.com/nuxt/nuxt/discussions/20495
- Nitro Caching-System (Cross-Prozess: Memory-Driver ist prozess-isoliert; Fremdprozess-Purge braucht
  shared Driver ODER internen Endpoint): https://deepwiki.com/nitrojs/nitro/5.3-caching-system
- Nuxt Prerendering — `prerender:true` ist bis zum nächsten Build eingefroren; `isr` ≈ swr auf Node:
  https://nuxt.com/docs/getting-started/prerendering

---

## 7. Umsetzungs-Reihenfolge 1.0 (nach WIP-Entsperrung)

> Sobald die WIP-Sperre fällt (Tim/Austin), in dieser Reihenfolge loslegen. Ziel: erst der
> Kern-SSR-Deploy-Pfad lauffähig + verifizierbar, dann Content-Refresh (A2), dann Härtung,
> dann die Freigabe-Bedingung (Voll-Parität + realer Deploy).

**Etappe 1 — Kern-Deploy lauffähig (P0, Gem-only, Cargo):** ✅ **GEBAUT auf `feat/ssr-1.0`
(2026-06-11, Cargo).** Code + Unit-/Render-Smoke grün (`ruby -c` + `test/ssr_template_smoke_test.rb`
+ `test/nuxt3_tasks_wiring_test.rb`). Echter Deploy-Verify steht noch aus (Robert, moja-Testbett).
1. **G1** ✅ ENV-File-Kontrakt (`EnvironmentFile=-…` ins Unit-Template + `ssr:upload_env`/`check_env`).
   Zuerst, weil alle folgenden Tasks die Laufzeit-ENV brauchen.
2. **G3** ✅ Build-ENV-Sourcing + Build-Logs-Fix (`tee`-Bug im nvm-Zweig) — Build muss sauber loggen,
   bevor man Fehler debuggt.
3. **G2** ✅ Flag-States vervollständigen (`restarting|deploy`, `ERROR-<task>|deploy`;
   `purging|admin-interface` kommt mit A2/Etappe 2) — Sichtbarkeit für alles Weitere.
4. **G4** ✅ Erst-Deploy-Ergonomie (Unit-Autodetect statt `nuxt3_ssr_hooks=false`-Tanz).
5. **G5** ✅ Health-Check `ssr:verify` nach Restart — ab hier schlägt ein kaputter Deploy laut fehl.

**Etappe 2 — Content-Refresh A2 (P0, FE/BE + kleine Gem-Konvention):**
6. **G14 (A2)** FE: `swr`-routeRules + interner Purge-Endpoint (Luke/Layer); BE: Worker-Innenleben
   `npm run export` → `curl …/_purge` (Bill); Gem dokumentiert die Purge-Konvention + ENV/Port-
   Kontrakt für den Endpoint. (Hängt an Etappe 1, weil ENV/Port-Kontrakt dort steht.)
7. **G15 (A2-Pflicht-Auflage)** Nitro-Version-Pin + Purge-Smoke-Test, der den Cache-Purge real
   verifiziert. **Direkt mit G14 zusammen** — ohne diesen Test ist A2 nicht 1.0-fähig.

**Etappe 3 — Härtung + Doku (P1):**
8. **G9** Specs (Dexter) für Task-Verkabelung + ERB-Template-Rendering.
9. **G10** Docs (Homer): README-SSR-Abschnitt + Migrations-Guide nuxt2→recipes4nuxt
   (inkl. „Worker → `curl`-Purge umbauen").
10. **G6 / G11 / G12** nach Tim-Priorisierung (Monit-Pairing / Alt-Task-Scope / `NUXT_APP_ENV`-Umsetzung).

**Etappe 4 — Freigabe (hart, Tim/Austin):**
11. **Voll-Parität zu `capistrano-nuxt2`** nachweisen (Deploy-Sichtbarkeit + Admin-Trigger gleichwertig).
12. **Ein realer, verifizierter Deploy** auf moja- und/oder ValidSlots-Testbett, grün durch
    (Build → Restart → Health-Check → Admin-Purge verifiziert). **Erst danach** WIP-Entsperrung / 1.0.

**Post-1.0 (P2, jederzeit danach):** G7 (echtes Zero-Downtime), G8 (`node_modules`-Hygiene),
G13 (Port-Doppelbelegungs-Check).
