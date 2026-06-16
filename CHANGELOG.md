# Changelog — capistrano-recipes4nuxt

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
