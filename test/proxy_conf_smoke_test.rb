# frozen_string_literal: true
#
# Standalone ERB render-smoke for the nginx proxy template.
#
# Guards the Q5 restart-gap weichmacher (proxy_next_upstream*, Contract §1.2):
# the directives must render with sensible defaults, honour overrides, and stay
# OUT of the config when explicitly disabled (empty/nil). No Capistrano / Rails /
# bundle needed — we stub fetch/render2go and mix in the REAL NginxHelpers so the
# domain/host logic is exercised faithfully.
#
# Run:  ruby test/proxy_conf_smoke_test.rb

require "erb"

LIB = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(LIB) unless $LOAD_PATH.include?(LIB)
require "capistrano/recipes4nuxt/nginx_helpers"

TEMPLATE = File.expand_path(
  "../lib/generators/capistrano/recipes4nuxt/templates/nginx_proxy_conf.erb", __dir__
)

class ProxyRenderContext
  include Capistrano::Recipes4nuxt::NginxHelpers

  def initialize(vars)
    @vars = vars
  end

  def fetch(key, default = nil)
    @vars.key?(key) ? @vars[key] : default
  end

  # The template renders the SSL-options partial via render2go — stub it.
  def render2go(_tmpl)
    "# (ssl options partial stubbed)"
  end

  def render(template_path)
    ERB.new(File.read(template_path)).result(binding)
  end
end

def base_vars(overrides = {})
  {
    application: "moja",
    stage: "production",
    nginx_proxy_site_name: "moja_production_proxy",
    nginx_upstream_host: "10.99.7.17",
    nginx_upstream_port: 3500,
    nginx_use_ssl: false,
    nginx_major_domain: false,
    nginx_domains: ["moja.example.com"],
    nginx_remove_www: true,
    allow_well_known_proxy: false,
    nginx_proxy_log_folder: "/var/log/nginx",
    # Q5 weichmacher defaults (mirror nuxt3/proxy_nginx.rake load:defaults):
    nginx_proxy_next_upstream: "error timeout http_502 http_503",
    nginx_proxy_next_upstream_tries: 2,
    nginx_proxy_next_upstream_timeout: "5s"
  }.merge(overrides)
end

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

def render_conf(overrides = {})
  ProxyRenderContext.new(base_vars(overrides)).render(TEMPLATE)
end

# === Case 1: defaults — weichmacher present ===================================
puts "Case 1: defaults (Q5 weichmacher)"
conf = render_conf
check("proxy_next_upstream renders with default conditions") do
  conf.include?("proxy_next_upstream error timeout http_502 http_503;")
end
check("proxy_next_upstream_tries renders default (2)") do
  conf.include?("proxy_next_upstream_tries 2;")
end
check("proxy_next_upstream_timeout renders default (5s)") do
  conf.include?("proxy_next_upstream_timeout 5s;")
end
check("directives sit inside the location / proxy block") do
  loc = conf.index("location / {")
  pnu = conf.index("proxy_next_upstream ")
  pass = conf.index("proxy_pass")
  loc && pnu && pass && loc < pnu && pnu < pass
end
check("defaults are idempotent-only (no non_idempotent / http_500 / http_504)") do
  !conf.include?("non_idempotent") && !conf.include?("http_500") && !conf.include?("http_504")
end

# === Case 2: override conditions/tries/timeout ================================
puts "Case 2: overrides"
conf = render_conf(
  nginx_proxy_next_upstream: "error timeout http_502",
  nginx_proxy_next_upstream_tries: 3,
  nginx_proxy_next_upstream_timeout: "8s"
)
check("overridden conditions render") { conf.include?("proxy_next_upstream error timeout http_502;") }
check("overridden tries render") { conf.include?("proxy_next_upstream_tries 3;") }
check("overridden timeout render") { conf.include?("proxy_next_upstream_timeout 8s;") }

# === Case 3: opt-out via empty/nil ===========================================
puts "Case 3: opt-out (empty)"
conf = render_conf(nginx_proxy_next_upstream: "")
check("empty value omits proxy_next_upstream entirely") do
  !conf.include?("proxy_next_upstream")
end
puts "Case 3b: opt-out (nil)"
conf = render_conf(nginx_proxy_next_upstream: nil)
check("nil value omits proxy_next_upstream entirely") do
  !conf.include?("proxy_next_upstream")
end

# === Case 4: SSL on still renders weichmacher (location / is in SSL block) =====
puts "Case 4: SSL on"
conf = render_conf(nginx_use_ssl: true)
check("weichmacher present in SSL server block too") do
  conf.include?("proxy_next_upstream error timeout http_502 http_503;")
end
check("upstream still points at the app server") do
  conf.include?("server 10.99.7.17:3500;")
end

puts
if $failures.zero?
  puts "ALL PROXY-CONF RENDER SMOKE CHECKS PASSED"
  exit 0
else
  puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
