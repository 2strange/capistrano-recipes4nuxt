# frozen_string_literal: true
#
# Standalone ERB render-smoke for the Nuxt 3 SSR systemd unit template.
#
# G9-prep (Etappe 1): no Capistrano / Rails / bundle needed — we stub the
# `fetch`/`shared_path`/`nuxt3_nvm_prefix` calls the template relies on and
# render the .erb directly, then assert on the produced unit file across the
# matrix (ENV file present, port, service name, nvm on/off).
#
# Run:  ruby test/ssr_template_smoke_test.rb
#
# Intentionally dependency-free (plain Ruby + erb/stringio) so it runs in CI
# and on a bare box without `bundle install`. The richer Capistrano-wired specs
# are Dexter's G9 follow-up; this guards the render contract right now.

require "erb"
require "stringio"

TEMPLATE = File.expand_path(
  "../lib/generators/capistrano/recipes4nuxt/templates/nuxt3_ssr_service.erb", __dir__
)

# Minimal render context that mimics the Capistrano DSL surface the template
# touches: fetch(:key) / fetch(:key, default), shared_path, nuxt3_nvm_prefix,
# and application/stage.
class RenderContext
  def initialize(vars)
    @vars = vars
  end

  def fetch(key, default = nil)
    @vars.key?(key) ? @vars[key] : default
  end

  def shared_path
    @vars.fetch(:shared_path)
  end

  def nuxt3_nvm_prefix
    "source #{fetch(:nuxt3_nvm_script)} && nvm use #{fetch(:nuxt3_nvm_version)}"
  end

  def render(template_path)
    ERB.new(File.read(template_path)).result(binding)
  end
end

def base_vars(overrides = {})
  {
    application: "moja",
    stage: "production",
    shared_path: "/home/deploy/moja/shared",
    nuxt3_ssr_user: "deploy",
    nuxt3_output_folder: "output",
    nuxt3_ssr_host: "127.0.0.1",
    nuxt3_ssr_port: 3500,
    nuxt3_ssr_env: {},
    nuxt3_ssr_env_file: "nuxt3_ssr.env",
    nuxt3_ssr_service_file: "moja_production_nuxt3_ssr",
    nuxt3_pid_path: "/home/deploy/moja/shared/pids",
    nuxt3_nvm_script: "$HOME/.nvm/nvm.sh",
    nuxt3_nvm_version: "20.19.0"
  }.merge(overrides)
end

# --- tiny assertion harness ---------------------------------------------------
$failures = 0
def check(desc)
  ok = yield
  if ok
    puts "  ok   #{desc}"
  else
    $failures += 1
    puts "  FAIL #{desc}"
  end
rescue => e
  $failures += 1
  puts "  FAIL #{desc}  (#{e.class}: #{e.message})"
end

def render_unit(overrides = {})
  RenderContext.new(base_vars(overrides)).render(TEMPLATE)
end

# === Case 1: defaults (no extra env hash, default port) =======================
puts "Case 1: defaults"
unit = render_unit
check("renders the optional ENV file (EnvironmentFile=- … nuxt3_ssr.env)") do
  unit.include?("EnvironmentFile=-/home/deploy/moja/shared/config/nuxt3_ssr.env")
end
check("ENV file line uses the optional '-' prefix (zero-config-safe)") do
  unit =~ /EnvironmentFile=-\S/
end
check("NITRO_PORT reflects nuxt3_ssr_port (3500)") do
  unit.include?("Environment=NITRO_PORT=3500") && unit.include?("Environment=PORT=3500")
end
check("service Description carries application + stage") do
  unit.include?("moja_production")
end
check("PIDFile points at the per-service pid path") do
  unit.include?("PIDFile=/home/deploy/moja/shared/pids/moja_production_nuxt3_ssr.pid")
end
check("ExecStart runs node against shared output server/index.mjs") do
  unit.include?("node /home/deploy/moja/shared/output/server/index.mjs")
end
check("ENV file is loaded AFTER the static Environment= lines (file wins)") do
  unit.index("Environment=NITRO_PORT=") < unit.index("EnvironmentFile=-")
end

# === Case 2: custom port (port-discipline on shared box) ======================
puts "Case 2: custom port 3601"
unit = render_unit(nuxt3_ssr_port: 3601)
check("custom NITRO_PORT renders") { unit.include?("Environment=NITRO_PORT=3601") }
check("custom PORT renders") { unit.include?("Environment=PORT=3601") }
check("port-discipline note present in comments") do
  unit.include?("unique per SSR") || unit.downcase.include?("eaddrinuse")
end

# === Case 3: extra env hash (nuxt3_ssr_env) ===================================
puts "Case 3: extra static Environment= entries"
unit = render_unit(nuxt3_ssr_env: { "NUXT_PUBLIC_FOO" => "bar" })
check("extra env hash becomes an Environment= line") do
  unit.include?("Environment=NUXT_PUBLIC_FOO=bar")
end
check("ENV file line still present alongside the static entry") do
  unit.include?("EnvironmentFile=-/home/deploy/moja/shared/config/nuxt3_ssr.env")
end

# === Case 4: nvm ExecStart wrapper ============================================
puts "Case 4: nvm-activated ExecStart"
unit = render_unit
check("ExecStart sources nvm before exec node") do
  unit.include?("nvm use 20.19.0") && unit.include?("ExecStart=/bin/bash -lc")
end

# === Case 5: custom env-file name override ====================================
puts "Case 5: overridden nuxt3_ssr_env_file"
unit = render_unit(nuxt3_ssr_env_file: "custom_ssr.env")
check("EnvironmentFile honours the overridden file name") do
  unit.include?("EnvironmentFile=-/home/deploy/moja/shared/config/custom_ssr.env")
end

# === Case 6: cross-host bind host 0.0.0.0 (G16) ===============================
puts "Case 6: cross-host nuxt3_ssr_host=0.0.0.0"
unit = render_unit(nuxt3_ssr_host: "0.0.0.0")
check("NITRO_HOST binds 0.0.0.0 (cross-host proxy)") do
  unit.include?("Environment=NITRO_HOST=0.0.0.0")
end
check("HOST binds 0.0.0.0 too") do
  unit.include?("Environment=HOST=0.0.0.0")
end
check("PORT/NITRO_PORT unchanged by host override") do
  unit.include?("Environment=NITRO_PORT=3500") && unit.include?("Environment=PORT=3500")
end
check("template carries the cross-host firewall security note") do
  unit.downcase.include?("firewall") && unit.include?("0.0.0.0")
end

# Default (single-host) still binds loopback — the safe default must not drift.
puts "Case 6b: default single-host bind stays 127.0.0.1"
unit = render_unit
check("default NITRO_HOST stays 127.0.0.1 (single-host safe default)") do
  unit.include?("Environment=NITRO_HOST=127.0.0.1") && unit.include?("Environment=HOST=127.0.0.1")
end

puts
if $failures.zero?
  puts "ALL ERB RENDER SMOKE CHECKS PASSED"
  exit 0
else
  puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
