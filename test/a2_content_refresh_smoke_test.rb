# frozen_string_literal: true

#
# Standalone smoke for the A2 Content-Refresh GEM-SIDE deliverables (0.8.0,
# Contract §6a / G14 + G15). The gem only owns the *mechanism + docs + harness*
# for A2 — the purge ENDPOINT is FE/Layer code (Luke), so there is nothing here
# that hits a live endpoint. This guards that the gem-side artifacts exist, the
# harness is shell-valid, and the honest scope-split is documented.
#
# Run:  ruby test/a2_content_refresh_smoke_test.rb
#
# Dependency-free (plain Ruby) so it runs on a bare box / CI without bundle.

ROOT = File.expand_path("..", __dir__)

HARNESS   = File.join(ROOT, "docs", "purge-smoke-test.sh")
PIN_DOC   = File.join(ROOT, "docs", "PURGE_SMOKE_TEST.md")
MIGRATION = File.join(ROOT, "docs", "migration-nuxt2-to-nuxt3-ssr.md")
HELPERS   = File.join(ROOT, "lib", "capistrano", "recipes4nuxt", "base_helpers.rb")
CONTRACT  = File.join(ROOT, "docs", "DEPLOY_CONTRACT.md")

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  ok   #{desc}" : "  FAIL #{desc}")
  $failures += 1 unless ok
rescue => e
  $failures += 1
  puts "  FAIL #{desc}  (#{e.class}: #{e.message})"
end

def body(path)
  File.file?(path) ? File.read(path) : ""
end

# === G15: purge smoke-test harness (the gem-shipped template) =================
puts "G15 — purge smoke-test harness (docs/purge-smoke-test.sh):"
check("harness file exists") { File.file?(HARNESS) }
check("harness is bash-syntax-valid (bash -n)") do
  File.file?(HARNESS) && system("bash", "-n", HARNESS, out: File::NULL, err: File::NULL)
end
hb = body(HARNESS)
check("harness drives a purge endpoint via PURGE_ENDPOINT") { hb.include?("PURGE_ENDPOINT") }
check("harness targets nuxt3_ssr_host:port via PURGE_BASE_URL") { hb.include?("PURGE_BASE_URL") }
check("harness sends the auth token (PURGE_TOKEN)") { hb.include?("PURGE_TOKEN") }
check("harness verifies invalidation (HIT→MISS / marker change)") do
  hb.downcase.include?("invalidat") && (hb.include?("MISS") || hb.include?("marker"))
end
check("harness honestly states the gem ships only the template (consumer wires endpoint)") do
  hb.include?("TEMPLATE") && hb.downcase.include?("not run by the deploy gem")
end

# === G15: version-pin recommendation doc ======================================
puts "G15 — version-pin doc (docs/PURGE_SMOKE_TEST.md):"
check("pin doc exists") { File.file?(PIN_DOC) }
pd = body(PIN_DOC)
check("recommends pinning nitropack/nuxt") { pd.include?("nitropack") && pd.include?("nuxt") }
check("cites the routeRules-purge risk (nuxt#20495)") { pd.include?("20495") }
check("labels the consumer-fulfilled obligation honestly") do
  pd.downcase.include?("consumer") && pd.downcase.include?("endpoint")
end

# === G14: migration doc A2 section + ENV/port contract ========================
puts "G14 — migration doc A2 section (docs/migration-nuxt2-to-nuxt3-ssr.md):"
md = body(MIGRATION)
check("has a Content-Refresh (A2) section") { md.include?("Content-Refresh") && md.include?("A2") }
check("documents the ENV/port contract the BE→Nitro curl needs") do
  md.include?("nuxt3_ssr_host") && md.include?("nuxt3_ssr_port") && md.include?("/api/_purge")
end
check("marks the purge endpoint as FE/Layer (Luke), NOT gem code") do
  md.include?("Luke") && (md.include?("NICHT das Deploy-Gem") || md.include?("nicht im Gem") || md.include?("❌ App-Code"))
end

# === G14: honest purging|admin-interface flag-state scope =====================
puts "G14 — flag-state scope honesty (base_helpers.rb + Contract §3.2):"
ch = body(HELPERS)
check("base_helpers documents purging|admin-interface") { ch.include?("purging|admin-interface") }
check("base_helpers says the DEPLOY GEM never writes that state") do
  ch.include?("DEPLOY GEM never writes") || ch.downcase.include?("never writes `purging")
end
cb = body(CONTRACT)
check("contract §3.2 abgrenzt purging|admin-interface as BE/Admin-written") do
  cb.include?("NICHT vom") && cb.include?("purging|admin-interface")
end

# === 1.0 scope split present in the contract ==================================
puts "1.0-definition split (gem-deploy-1.0 vs FE-A2 follow-up):"
check("contract separates 1.0-A (Gem-Deploy-1.0) from 1.0-B (FE A2)") do
  cb.include?("1.0-A") && cb.include?("1.0-B")
end
check("contract names the open Re-Deploy-Verify as the only open gem verification") do
  cb.include?("Re-Deploy-Verify")
end

puts
if $failures.zero?
  puts "ALL A2 (G14/G15) GEM-SIDE SMOKE CHECKS PASSED"
  exit 0
else
  puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
