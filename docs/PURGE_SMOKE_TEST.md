# A2 Purge — Nitro-Version-Pin + Smoke-Test (Contract G15)

> **Pflicht-Auflage zu A2, nicht optional** (Austin 2026-06-11, `DEPLOY_CONTRACT.md`
> §6a/§5/G15). Diese Datei + `docs/purge-smoke-test.sh` sind die **Gem-Lieferung**
> für G15. Der eigentliche Purge-**Endpoint** ist FE/Layer-Code (Luke), **nicht** das
> Gem — die Auflage **erfüllt der Consumer mit seinem Endpoint**.

---

## Warum das eine Pflicht-Auflage ist (das Risiko ehrlich benannt)

Der A2-Content-Refresh setzt Content-Routen auf `swr` (stale-while-revalidate) und
purged den Cache on-demand über:

```ts
await useStorage('cache').clear('nitro:routeRules')
```

⚠️ **Es gibt kein offizielles, dokumentiertes Invalidierungs-API für routeRules-Caches.**
Das `.invalidate()`-API existiert nur für `defineCachedFunction` /
`defineCachedEventHandler` — **nicht** für routeRules. Der Storage-Key-Prefix-Purge
(`nitro:routeRules`) funktioniert, ist aber **internes, undokumentiertes** Nitro-Verhalten
([nuxt#20495 — „no way to clear or bypass routeRules cache"](https://github.com/nuxt/nuxt/discussions/20495)).

**Konsequenz:** Ein Nitro-/Nuxt-Upgrade kann das Cache-Key-Schema oder den Storage-Mount
ändern, ohne dass ein Test fehlschlägt — der Purge läuft dann **lautlos ins Leere**
(`clear()` trifft keine Keys), und Content bleibt bis TTL stale, obwohl der Admin „jetzt
aktualisieren" gedrückt hat. Das ist ein **stiller** Failure-Mode → genau deshalb:
**Version-Pin + Smoke-Test sind Pflicht-Bestandteil von 1.0**, nicht Kür.

---

## Auflage 1 — Nitro/Nuxt **pinnen** (Consumer-`package.json`)

Pinne **exakt** (kein `^`/Caret) die Version, gegen die du den Purge verifiziert hast:

```json
{
  "dependencies": {
    "nuxt": "3.13.2"
  },
  "overrides": {
    "nitropack": "2.9.7"
  }
}
```

- `nuxt` exakt pinnen; `nitropack` zusätzlich über `overrides` (npm) bzw. `resolutions`
  (yarn/pnpm) festnageln, damit ein transitives Nitro-Bump nicht durchrutscht — der
  Purge-Pfad hängt an der **Nitro**-internen Cache-Mechanik, nicht direkt an Nuxt.
- **Regel:** Vor **jedem** Nuxt/Nitro-Bump → erst Smoke-Test gegen die neue Version
  (Auflage 2), dann erst den Pin hochziehen. Bump ohne grünen Smoke-Test = A2 ist nicht
  mehr 1.0-konform.

### Getestete Referenz-Matrix

Trage hier ein, wogegen der Purge nachweislich grün lief (Consumer pflegt das pro App):

| Nuxt | Nitropack | Purge verifiziert | Datum | von |
|---|---|---|---|---|
| _z. B. 3.13.2_ | _2.9.7_ | ⬜ noch offen | – | – |

> Die konkrete „bekannt-gute" Version legt der **Consumer** beim ersten realen A2-Deploy
> fest (er hat die App + den Endpoint). Das Gem gibt das **Verfahren** vor, nicht die Zahl.

---

## Auflage 2 — **Purge-Smoke-Test** gegen DEINEN Endpoint (`docs/purge-smoke-test.sh`)

Das Gem liefert die **Harness/Vorlage** (`docs/purge-smoke-test.sh`). Scharf schaltest du
sie, indem du sie gegen deine laufende Nitro-Instanz + deinen `_purge`-Endpoint laufen
lässt. **Das Gem kann den Test nicht selbst fahren** — es existiert kein Endpoint im Gem
(Nitro-Route = FE/Layer-Revier). Diese Trennung ist Absicht.

### Was der Test beweist

1. Eine `swr`-gecachte Content-Route wird zweimal abgerufen → der 2. Hit kommt **aus dem Cache**.
2. Der Test ruft deinen `POST /api/_purge` (mit Token) auf.
3. Der nächste Abruf **muss frisch re-rendern** (Cache-MISS / neuer Render-Marker).

Schlägt Schritt 3 fehl → **G15-Risiko ist real eingetreten**: der Purge hat nichts geleert.
Dann Nitro-Pin prüfen / das `nitro:routeRules`-Key-Prefix inspizieren (nuxt#20495). Genau
das soll der Test **vor** dem Produktiv-Bump fangen.

### Voraussetzung im FE/Layer (Luke) — damit der Test detektieren kann

Der Test braucht **ein** beobachtbares Signal „cached vs. frisch gerendert". Wähle eins:

- **`PURGE_DETECT=header`** — dein `_purge`/Render-Pfad setzt einen Cache-Status-Header
  (`X-Nitro-Cache: HIT|MISS` o. ä.). Sauberster Weg.
- **`PURGE_DETECT=marker`** (Default) — die Seite enthält einen **pro Render** wechselnden
  Marker (z. B. einen server-seitig injizierten ISO-Timestamp). Der Test extrahiert ihn per
  Regex (`PURGE_MARKER_RE`) und vergleicht vor/nach Purge.

### Ausführen

```bash
PURGE_BASE_URL=http://127.0.0.1:3500 \   # = nuxt3_ssr_host:nuxt3_ssr_port
PURGE_ROUTE=/ \                          # eine swr-gecachte Content-Route
PURGE_ENDPOINT=/api/_purge \
PURGE_TOKEN="$NUXT_PURGE_TOKEN" \        # == Token in shared/config/nuxt3_ssr.env
PURGE_DETECT=header PURGE_HEADER=X-Nitro-Cache \
./docs/purge-smoke-test.sh
```

Exit-Codes: `0` = Purge verifiziert · `1` = Purge invalidiert **nicht** (G15-Risiko!) ·
`2` = Fehlkonfiguration / Endpoint nicht erreichbar.

> **CI-Tipp (Consumer):** den Test als Pflicht-Gate vor jedem Nuxt/Nitro-Bump in die
> Consumer-CI hängen (gegen eine Preview-/Staging-Nitro-Instanz). Damit kann ein Upgrade
> den stillen Purge-Bruch nicht unbemerkt mergen.

---

## Revier-Zusammenfassung (was Gem vs. Consumer)

| Teil | Wer | Liegt wo |
|---|---|---|
| Smoke-Test-Harness + diese Anleitung + Pin-Empfehlung | **Cargo (Gem)** ✅ | `docs/purge-smoke-test.sh`, `docs/PURGE_SMOKE_TEST.md` |
| `server/api/_purge`-Endpoint + Cache-Status-Signal (Header/Marker) | **Luke (FE/Layer)** | Consumer-App / Layer |
| `swr`-routeRules | **Luke (FE/Layer)** | `nuxt.config.ts` |
| BE-Worker `curl …/_purge` | **Bill (BE)** | Consumer-BE |
| Exakte gepinnte Version eintragen + Test scharf fahren | **Consumer** | Consumer-`package.json` / CI |

**→ Auflage G15 ist gem-seitig erfüllt (Harness + Pin-Verfahren geliefert); die
Verifikation gegen einen echten Endpoint erfüllt der Consumer mit seinem Endpoint.**
