# Changelog — capistrano-recipes4nuxt

## 1.2.0 — 2026-10-15

**Neu: Next.js-Rezept + generische systemd-Timer + PostgreSQL-Rollen/DB.** Rein additiv —
Nuxt-Tasks/Templates/Defaults unverändert; ohne `require` der neuen Rezepte ändert sich nichts.

- **feat (`capistrano/recipes4nuxt/next`):** Deploy für Next.js mit `next start`, eigene
  `next_*`-Settings. Atomar: `npm ci` pro Release + `next build` + `:next_pre_publish_cmds`
  (z. B. Migrationen) laufen in `deploy:updated`, also **vor** dem `current`-Switch — ein roter
  Build läuft nie live. systemd-Unit aus `current/`, `HOSTNAME`/`PORT`, Runtime-ENV
  `shared/config/next.env` (0600, auch beim Build gesourct), optionaler Secrets-Ordner (0700),
  Health-Check, `next:check_env` warnt vor secret-artigen `NEXT_PUBLIC_*`. Bricht ab, wenn
  zusätzlich ein Nuxt-Rezept in der Capfile steckt.
- **feat (`capistrano/recipes4nuxt/timers`):** `:systemd_timers`-Liste → je Job eine
  oneshot-Service- + Timer-Unit (flock, App-ENV, nvm); veraltete Timer werden entfernt.
  Framework-agnostisch; vorerst nur hier, Port nach recipes2go bei Bedarf.
- **feat (`capistrano/recipes4nuxt/postgres`):** Login-Rollen (mit Attributen, z. B.
  `BYPASSRLS`) + DB (Owner, Encoding, Locale, template0) + Extensions, URLs nach
  `shared/config/database.env` (0600). Passwörter nur via stdin, nie in der Kommandozeile.
  Fremde bestehende Rollen werden nie still zurückgesetzt.
- **feat (proxy):** `:nginx_proxy_forwarded_for` (Default unverändert
  `$proxy_add_x_forwarded_for`; `$remote_addr` überschreibt → kein IP-Spoofing bei Rate-Limits).
- **chore (G17/G18):** App-Nginx- und Nuxt2-Hook greifen auch bei `:next_app` nicht.
- Erster Konsument: mary (interview-Team). Verify-Deploy steht noch aus.

## 1.1.2 — 2026-10-15

**Security: die hochgeladene Runtime-ENV-Datei ist jetzt nur noch für den deploy-User lesbar.**

- **fix (`nuxt3:ssr:upload_env`):** `shared/config/nuxt3_ssr.env` enthält Secrets, wurde
  aber per `rsync -av` mit dem **lokalen** Dateimodus hochgeladen (meist `0644` → für
  alle User auf dem Server lesbar). Jetzt `rsync --chmod=F600` + `chmod 600` danach —
  auch eine schon vorhandene, zu offene Datei wird beim nächsten Deploy/Upload
  korrigiert. Der Nitro-Service läuft als deploy-User und liest sie unverändert.
  Keine neue Config nötig.

## 1.1.1 — 2026-10-15

**Fix: `certbot_www_domains` erzeugte kaputte certbot-Argumente.**

- **fix (certbot):** In `fetch_certbot_domain_args` fehlte das Leerzeichen vor dem
  zweiten `-d` → aus `example.com` wurde `-d example.com-d www.example.com`.
  Betrifft nur Stages mit `set :certbot_www_domains, true`; alle anderen
  rendern unverändert. (Fund: interview-Bob, 2026-10-15)

## 1.1.0 — 2026-06-16

**Setup zieht jetzt das SSL-Cert mit — „nach `cap <stage> setup` einfach deployen".**
Rein additiv; bestehende Tasks/Templates/Defaults und der SSR-Deploy-Pfad unverändert.

- **feat (Let's Encrypt im Setup):** neues Mini-Template `nginx_letsencrypt.conf.erb` +
  Task `certbot:bootstrap`. Lädt einen **minimalen ACME-only `:80`-vhost** hoch
  (nur `.well-known/acme-challenge` → `:certbot_webroot`, **kein** Upstream/SSL/
  Container-Bezug), zieht das Cert (`certbot:generate`) und entfernt den vhost
  wieder. Damit steht das Zertifikat **vor** dem ersten Deploy — kein Flag-Toggle-
  Dance, kein „Proxy wegfeuern" durch eine SSL-Config ohne Cert. Läuft auf
  `:certbot_roles` (im Proxy-Setup `[:proxy]`).
- **feat (Setup-Aggregat erweitert):** `cap <stage> setup` ruft jetzt zusätzlich
  `certbot:bootstrap` (wenn `:nginx_use_ssl`).
- **chore:** `certbot.rake` lädt explizit `base_helpers` + `nginx_helpers`
  (für `template2go`/Domain-Helper im neuen Task).

> Die Nitro-SSR-systemd-Unit wird im Setup **nicht** angefasst — sie braucht den
> gebauten Output und wird beim ersten Deploy automatisch konfiguriert (G4,
> `nuxt3:ssr:restart`). Da ändert sich nichts.

> Nutzung pro App in `config/deploy/<stage>.rb`, z.B.:
> `set :nginx_use_ssl, true` · `set :certbot_email, "…"` ·
> `set :certbot_roles, [:proxy]` · `set :certbot_webroot, "/var/www/html"`.
