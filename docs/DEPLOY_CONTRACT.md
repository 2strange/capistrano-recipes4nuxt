# DEPLOY_CONTRACT.md — Nitro-SSR-Deploy-Kontrakt (recipes4nuxt)

> **Status: DESIGN-ENTWURF** — Branch `design/nitro-deploy-contract`, kein Release.
> Autor: Cargo (myTOOLZ release) · Stand: 2026-06-11 · Review: Tim → Austin.
>
> **Update 2026-06-11 (Austin Q1–Q4 entschieden):** Q1 systemd (PM2 raus) = DECIDED ·
> Q2 Admin-Rebuild-Trigger bleibt **funktionell erhalten** (Override des alten §3.2 „entfällt
> ersatzlos"), nur das Mittel ist offen → Variantenvergleich **§6a** · Q3 ENV-File = DECIDED ·
> Q4 `NUXT_APP_ENV` = DECIDED (Mehrfach-Instanz-Hinweis in §4 ergänzt) · Q5 Restart-Gap-Empfehlung
> dokumentiert (Nod ausstehend). Die Q6-Entscheidung (swr-Purge vs prerender-Rebuild) liegt in §6a.
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
| Content-Aktualität | eingefroren bis zum nächsten Render | je nach Variante (§6a): **SWR zur Laufzeit** (routeRules, TTL) ODER **prerender + Trigger-Rebuild** |
| Admin-Rebuild-Trigger | Kern-Feature (Sidekiq-Worker, `npm run export`) | **bleibt funktionell**, Mittel offen (s. §3.2 + §6a) |
| Laufzeit-Abhängigkeit | keine (nur nginx) | Node-Prozess muss überwacht laufen (s. §2) |

⚠️ Bewusster Trade-off (**Q5**): `systemctl restart` hat einen **kurzen Downtime-Gap** (Sekunden,
Nitro bootet schnell), und das `rsync --delete` in `shared/output/` tauscht Dateien unter dem
laufenden Prozess (der alte Prozess hält sein `index.mjs` offen — ESM ist beim Start geladen,
Assets unter `.output/public` könnten kurz mixen). Für **On-Prem mit 1 Instanz/Kunde**
akzeptieren wir das für 1.0.

**Cargo-Empfehlung Q5 (Nod ausstehend):** Gap für 1.0 **akzeptieren** + billiger Weichmacher:
nginx `proxy_next_upstream error timeout http_502` (+ `proxy_next_upstream_tries 2`), sodass ein
Request, der genau ins Restart-Fenster fällt, automatisch einen zweiten Versuch bekommt — bei
einem Sekunden-Restart fällt das real praktisch nie auf. **Echtes** Zero-Downtime
(Port-Flip: zwei Units A/B + nginx-Upstream-Switch, oder Socket-Activation) = **post-1.0 / Gap G7**.
→ Austin muss nur ja/nein zu „1.0 akzeptiert + `proxy_next_upstream`-Weichmacher" sagen.

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

### 3.2 BLEIBT FUNKTIONELL — Admin-Rebuild-Trigger (Q2-Override, Austin 2026-06-11)

> ⚠️ **OVERRIDE des früheren Entwurfs.** Der alte §3.2 sagte „ENTFÄLLT ersatzlos". Das ist
> **überholt.** Austin 2026-06-11: *„admin trigger muss funktionell möglich, triggert aktuell
> einen sidekiq task der die seite neu rendert."* Der Admin-Trigger **bleibt als Funktion
> erhalten** — die offene Entscheidung ist nur das **Mittel** dahinter. Beide Mittel-Varianten
> sind in **§6a** vollständig ausgearbeitet; Austin entscheidet dort A vs B.

Was das konkret heißt:

- Der **Admin-Button** (heute `renderState.vue` → `$admin.index('rebuild_frontend')`) und der
  **BE-Endpoint** `GET rebuild_frontend` (heute `BuildFrontendWorker.perform_async`) bleiben.
  Nur die **Aktion**, die der Worker ausführt, ändert sich je nach Variante:
  - **Variante A (swr + Cache-Purge):** Trigger → leichtgewichtiger **Purge der Nitro-Route-Caches**
    → nächster Request rendert frisch. Kein npm-Build. (§6a-A)
  - **Variante B (prerender + Rebuild):** Trigger → echter **Re-Render/Build** der prerender-Routen
    (näher am Ist: heute Sidekiq → `npm run export`). (§6a-B)
- Der **Flag-Datei-Status-Kontrakt** (§3.1, `_builded_app`/`_builded_logs`/`_builded_frontend`)
  bleibt in **beiden** Varianten der Lesekontrakt für die Admin-UI — die UI zeigt weiter
  „zuletzt aktualisiert / läuft gerade". In Variante A zeigt sie zusätzlich die SWR-TTL
  („Inhalte spätestens nach N Min frisch"), in Variante B den Build-Status wie heute.
- **Akteur-States im SSR-Pfad:** `initialized|admin-interface` + `purging|admin-interface`/
  `rendering|admin-interface` (Variante A bzw. B) bleiben/kommen — der Akteur-Teil (`admin-interface`
  vs `deploy`) trennt weiterhin „Admin hat getriggert" von „Deployment lief". Detail in §6a.
- `generating|deploy` taucht im SSR-Pfad nur in **Variante B** (Rebuild) auf; in Variante A nie.

**Revier-Abgrenzung (gilt für beide Varianten):** recipes4nuxt liefert die **Deploy-/Task-Seite**
(Tasks, Unit-Template, optional Purge-Endpoint-Konvention/Task). Der **Admin-Button (FE)** ist
**Luke-Revier**, der **BE-Endpoint/Worker** ist **Bill-Revier** (slots). Genaue Slot-Schnitte
pro Variante in §6a, Punkt (2).

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

**Vorschlag (Gap G13, nicht implementieren):** ein optionaler Doppelbelegungs-Check
`nuxt3:ssr:check_port` — vor `ssr:configure`/`restart` prüfen, ob `<port>` bereits von einer
**fremden** Unit belegt ist (z. B. `ss -ltnp 'sport = :<port>'` bzw. Abgleich der vorhandenen
`*_nuxt3_ssr.service`-EnvironmentFiles auf denselben `NITRO_PORT`), und mit klarer Meldung
abbrechen statt mit `EADDRINUSE` im journal zu enden. Reiner Ergonomie-Guard, blockt nichts
Bestehendes (zero-config-safe).

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
| G12 | **Neutrale Deploy-Mode-Var** (`NUXT_APP_ENV` statt `build_deploy_env_var`-Konstrukt), abwärtskompatibel (Drop-in-Update-Regel!) — ✅ Q4 DECIDED | S | mittel |
| G13 | **Port-Doppelbelegungs-Check** `nuxt3:ssr:check_port` (§4.4): warnt bei `<port>`-Kollision auf geteilter Box statt `EADDRINUSE` im journal; reiner Ergonomie-Guard | S | niedrig |
| G14 | **Content-Refresh-Mechanik = Ergebnis §6a** (A oder B). Bei **A**: Purge-Task/-Konvention `nuxt3:ssr:purge_cache` + Cache-Storage-Driver-Vorgabe (fs/redis, shared) im Unit/ENV-Kontrakt; bei **B**: `nuxt3:rebuild`-Task (vom BE-Worker via SSH/cap angestoßen) + Re-Render-States. Genauer Schnitt + Aufwand in §6a | M (A) / M–L (B) | **hoch** (blockt slots-Trigger) |
| G15 | **Purge-Pfad-Risiko (nur Variante A)**: routeRules-`swr`-Cache hat **kein First-Class-Invalidierungs-API** (s. §6a-A „Risiko"); Purge über Storage-Key-Prefix `nitro:routeRules`/`nitro:handlers` ist **internes/undokumentiertes** Verhalten → braucht Smoke-Test + Pin auf getestete Nitro-Version, sonst Bruchgefahr bei Updates | S–M | **hoch** (Entscheidungs-Risiko für A) |

Definition „1.0 = SSR vollständig": G1–G5 umgesetzt + G9/G10 grün + **G14** (Content-Refresh-Mittel
implementiert, A oder B); G6/G11/G12 nach Tim-Priorisierung; G7/G8/G13 dürfen post-1.0; G15 nur
relevant falls Variante A gewählt.

---

## 6. Offene Fragen (→ Austin via Tim)

| # | Frage | Status / Kontext |
|---|---|---|
| Q1 | **systemd bestätigen, PM2 verwerfen?** (§2) | ✅ **DECIDED 2026-06-11: systemd, PM2 raus** |
| Q2 | Admin-Rebuild-Trigger streichen? | ✅ **DECIDED 2026-06-11: Trigger BLEIBT funktionell** (Override §3.2); Mittel offen → **§6a / Q6** |
| Q3 | **ENV-File-Konvention ok?** Lokal `config/nuxt_env/<stage>.env` (gitignored) → `shared/config/nuxt3_ssr.env` | ✅ **DECIDED 2026-06-11: ja** → G1 frei |
| Q4 | **Neutrale Deploy-Mode-Variable** `NUXT_APP_ENV`? Mehrfach-Instanz-Frage? | ✅ **DECIDED 2026-06-11: `NUXT_APP_ENV` ok**; Mehrfach-Box geklärt (§4.4 — nur `nuxt3_ssr_port` muss eindeutig sein) |
| Q5 | **Zero-Downtime-Anspruch**: Sekunden-Restart-Gap für On-Prem 1.0 akzeptiert (G7 = post-1.0)? | 🟡 **Nod ausstehend** — Cargo-Empfehlung: 1.0 akzeptieren + nginx `proxy_next_upstream`-Weichmacher (§1.2). Austin: ja/nein? |
| Q6 | **Content-Refresh-Mittel: Variante A (swr + Cache-Purge) vs Variante B (prerender + Rebuild-Trigger)?** | 🟡 **OFFEN — Entscheidung steht an.** Voller Vergleich + Cargo-Empfehlung in **§6a**. (slots-FE Luke / BE Bill betroffen) |

---

## 6a. Content-Refresh — Variantenvergleich (Q6 + Q2)

> **Worum es geht:** Der Admin-Rebuild-Trigger **bleibt** (Q2-Override, §3.2). In **beiden**
> Varianten drückt der Admin denselben Button und die Flag-Status-UI funktioniert weiter — der
> Unterschied ist **das Mittel**, mit dem „frischer Content" entsteht. Heute (Nuxt2-Ist):
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

### Variante A — `swr` + Cache-Purge-Trigger  *(Tim-Empfehlung)*

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

### Variante B — `prerender` + Rebuild-Trigger  *(näher am Ist)*

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

### 6a.y Cargo-Empfehlung

**→ Variante A (swr + interner Purge-Endpoint A2) — mit einer ehrlichen Risiko-Auflage.**

Begründung: A ist betrieblich klar überlegen — sofortige Frische bei minimaler Last, graceful bei
Fehlern, skaliert bei häufigen Content-Edits, kein Restart-Gap pro Klick, und die Gem-Last ist klein
(Kern liegt sauber in FE/BE-Slots). Der entscheidende Vorbehalt ist **G15**: routeRules-Cache-Purge
hat **kein offizielles API**; der Storage-Prefix-Purge ist internes Verhalten. Das entschärfe ich
durch **A2 (interner Purge-Endpoint statt Fremdprozess-Storage-Zugriff)** + **Nitro-Version-Pin +
Smoke-Test** — dann ist das Restrisiko ein Versions-Upgrade-Check, kein Architektur-Problem.

**Wenn Austin das Purge-Restrisiko NICHT tragen will**, ist **Variante B** der sichere, aber teurere
Fallback (Standard-Build, kein API-Risiko) — Preis: mehr Gem-Arbeit, Build-Last + Restart-Gap pro
Klick, eingefrorener Content zwischen Klicks. Beide halten den Admin-Trigger funktionell (Q2 erfüllt).

**Mein Votum: A2.** B nur, falls das undokumentierte Purge-Verhalten als No-Go gilt.

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
