# DEPLOY_CONTRACT.md — Nitro-SSR-Deploy-Kontrakt (recipes4nuxt)

> **Status: DESIGN-ENTWURF** — Branch `design/nitro-deploy-contract`, kein Release.
> Autor: Cargo (myTOOLZ release) · Stand: 2026-06-10 · Review: Tim → Austin.
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
| Content-Aktualität | eingefroren bis zum nächsten Render | **SWR/ISR zur Laufzeit** (routeRules), kein Re-Render nötig |
| Admin-Rebuild-Trigger | Kern-Feature (Sidekiq-Worker) | **entfällt** (s. §3) |
| Laufzeit-Abhängigkeit | keine (nur nginx) | Node-Prozess muss überwacht laufen (s. §2) |

⚠️ Bewusster Trade-off: `systemctl restart` hat einen **kurzen Downtime-Gap** (Sekunden,
Nitro bootet schnell), und das `rsync --delete` in `shared/output/` tauscht Dateien unter dem
laufenden Prozess (der alte Prozess hält sein `index.mjs` offen — ESM ist beim Start geladen,
Assets unter `.output/public` könnten kurz mixen). Für **On-Prem mit 1 Instanz/Kunde**
akzeptieren wir das für 1.0; Zero-Downtime-Optionen (Port-Flip/Socket-Activation) = post-1.0
(Gap G7).

### 1.3 Static-Mode bleibt

`set :nuxt3_deploy_mode, :static` (Content-Sites): `nuxi generate` → `shared/www/` → nginx,
**kein** Node-Service. Der Hook routet automatisch. Dieser Kontrakt hier beschreibt den
SSR-Pfad; der Static-Pfad behält das alte nuxt2-Verhalten 1:1 (inkl. Flag-File-Semantik).

---

## 2. Service-Management: PM2 vs. systemd → **Empfehlung: systemd**

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

### 3.2 ENTFÄLLT ersatzlos — Admin-Rebuild-Trigger (Worker-Pfad)

- States `initialized|admin-interface`, `running|worker`, `success|worker`,
  `ERROR-<n>|worker` — es gibt keinen Sidekiq-`BuildFrontendWorker` mehr, der
  `npm run export` fährt: **SWR macht den Content-Rebuild zur Laufzeit-Eigenschaft.**
- Der `rebuild_frontend`-Endpoint + Debounce-Logik (6-min-Fenster) im BE: obsolet.
- Die „Seite muss neu gerendert werden!"-Warnung der Admin-UI: obsolet; die UI sollte
  stattdessen Deploy-Status (§3.1) + die konfigurierte **SWR-TTL** anzeigen
  („Inhalte erscheinen spätestens nach N Minuten"). → FE-/BE-Umbau ist **slots-Revier**
  (Luke/Bill), recipes4nuxt liefert nur die Deploy-Seite des Kontrakts.
- `generating|deploy` taucht im SSR-Pfad nicht mehr auf (nur noch Static-Mode).

**Grenzfall — prerenderte Routen** (`prerender: true` in routeRules, z. B. `/`):
deren HTML entsteht beim `nuxt build` und friert bis zum nächsten Deploy ein. Empfehlung:
Marketing-Routen mit redaktionellem Content **auf `swr` statt `prerender`** stellen, dann
gibt es genau null Rebuild-Bedarf; alternativ bleibt `cap <stage> deploy` der „Re-Render".
*(Entscheid liegt im slots-FE/routeRules, nicht im Gem — hier nur dokumentiert.)*

---

## 4. ENV-Kontrakt pro On-Prem-Instanz

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
„Maybe nonsense" markiert) wird durch eine **neutrale** Variable ersetzt — Vorschlag
`NUXT_APP_ENV=<stage>` via `default_env` (deckt auch ValidSlots' De-Brand-Wunsch
`SLOTS_DEPLOY_MODE` generisch ab) → **offene Frage Q4**.

---

## 5. Gap-Liste: v0.5.0 → Milestone 1.0 („SSR vollständig")

| # | Gap | Aufwand | Prio |
|---|---|---|---|
| G1 | **ENV-File-Kontrakt**: `EnvironmentFile=-…/nuxt3_ssr.env` ins Unit-Template + Tasks `nuxt3:ssr:upload_env` / `check_env` (keys-Muster, §4.2) | M | **hoch** |
| G2 | **Flag-File-Vervollständigung SSR**: State `restarting\|deploy`; `ERROR-<task>\|deploy` bei Task-Fehlschlag (Fehler-Sichtbarkeit in der Admin-UI) | S | **hoch** |
| G3 | **Build-Logs + Build-ENV**: `nuxt build` loggt heute NICHT nach `_builded_logs` (nur `generate`, und auch dort fehlt das `tee` im nvm-Zweig — Bug); Build-Tasks sourcen das ENV-File (§4.3) | S–M | **hoch** |
| G4 | **Erst-Deploy-Ergonomie**: Hook prüft `systemctl cat <unit>` — Unit fehlt → automatisch `ssr:configure` statt Restart; `nuxt3_ssr_hooks=false`-Tanz entfällt | S | **hoch** |
| G5 | **Health-Check** `nuxt3:ssr:verify` nach Restart (curl `127.0.0.1:<port>` mit Retry, Deploy schlägt fehl statt still kaputt); ans Hook-Ende | S | **hoch** |
| G6 | **Monit-Pairing**: Monit-Template für die Nitro-Unit (PIDFile existiert schon), analog recipes2go `monit.rake` | M | mittel |
| G7 | **Zero-Downtime dokumentieren/optional lösen**: Restart-Gap + `rsync --delete` unter laufendem Prozess (§1.2); Option Port-Flip (zwei Units A/B + nginx-Upstream-Switch) oder Socket-Activation | L | niedrig (post-1.0 ok) |
| G8 | **`node_modules`-Hygiene**: `rm -rf node_modules/*` + shared bei jedem Deploy = teuer; npm-Cache-Strategie prüfen (npm ci ist schon drin) | M | niedrig |
| G9 | **Tests (Dexter)**: Specs für Task-Verkabelung + ERB-Template-Rendering (Unit-File mit/ohne ENV-File, nvm an/aus) | M | mittel |
| G10 | **Docs (Homer)**: README-SSR-Abschnitt mit diesem Kontrakt abgleichen; Migrations-Guide nuxt2→recipes4nuxt (inkl. „Worker/Trigger abbauen") | S | mittel |
| G11 | **Scope-Entscheid Alt-Tasks**: `nuxt.rake` (Nuxt2) + `vue.rake` carry-over — in 1.0 behalten (Migrationspfad) oder deprecaten? | S | mittel |
| G12 | **Neutrale Deploy-Mode-Var** (`NUXT_APP_ENV` statt `build_deploy_env_var`-Konstrukt), abwärtskompatibel (Drop-in-Update-Regel!) | S | mittel |

Definition „1.0 = SSR vollständig": G1–G5 umgesetzt + G9/G10 grün; G6/G11/G12 nach
Tim-Priorisierung; G7/G8 dürfen post-1.0.

---

## 6. Offene Fragen (→ Austin via Tim)

| # | Frage | Kontext |
|---|---|---|
| Q1 | **systemd bestätigen, PM2 verwerfen?** (§2 — Empfehlung: ja) | betrifft alle künftigen SSR-Konsum-Apps |
| Q2 | **Admin-Rebuild-Trigger wirklich ersatzlos streichen** und die Admin-UI auf „Deploy-Status + SWR-TTL" umstellen? (§3.2 — BE/FE-Seite = Bill/Luke, nicht Gem) | ValidSlots-Kern-Feature ändert Bedeutung |
| Q3 | **ENV-File-Konvention ok?** Lokal `config/nuxt_env/<stage>.env` (gitignored) → `shared/config/nuxt3_ssr.env`; Inhalte pro Kunde = Austin (T4) | §4.2; Format/Pfade vor G1 festzurren |
| Q4 | **Neutrale Deploy-Mode-Variable** `NUXT_APP_ENV` als Standard (ValidSlots mappt darauf statt `SLOTS_DEPLOY_MODE`)? | §4.3 / G12 |
| Q5 | **Zero-Downtime-Anspruch**: Sekunden-Restart-Gap für On-Prem 1.0 akzeptiert (G7 = post-1.0)? | §1.2 |
| Q6 | Sollen prerenderte Marketing-Routen empfohlen auf `swr` umgestellt werden, damit „Content-Rebuild" als Konzept komplett verschwindet? (Doku-Empfehlung §3.2) | Abstimmung mit slots-FE (Luke) |
