# frozen_string_literal: true
#
# Standalone wiring-smoke for the deploy_mode-aware hook fixes (0.7.0):
#   G17 — proxy_nginx App-Nginx hook MUST be skipped in :ssr mode (port collision
#         with Nitro → host-wide `nginx -t` invalid → 502-incident). :static and
#         the plain Rails/recipes2go-proxy case (nuxt3_deploy_mode unset) MUST be
#         unchanged.
#   G18 — Nuxt2 nuxt.rake `deploy:published` rebuild hook MUST be skipped whenever
#         `nuxt3_deploy_mode` is set (the nuxt3 path owns deploy:published). A pure
#         Nuxt2 deploy (mode unset) MUST still rebuild.
#
# Run:  ruby test/deploy_mode_hooks_smoke_test.rb
#
# No real Capistrano/SSHKit/server — we stub the load-time DSL, then RE-EVALUATE
# the relevant hook/default bodies under different `nuxt3_deploy_mode` settings
# and record what they would invoke.

require "rake"

LIB_DIR = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(LIB_DIR) unless $LOAD_PATH.include?(LIB_DIR)

PROXY_RAKE = File.expand_path("../lib/capistrano/tasks/proxy_nginx.rake", __dir__)
NUXT2_RAKE = File.expand_path("../lib/capistrano/tasks/nuxt.rake", __dir__)

# --- captured state -----------------------------------------------------------
$settings = {}
$after_hooks = {}   # name => block
$invoked = []       # task names invoked by a hook body

module CapStub
  def set(key, value = nil, &blk); $settings[key] = blk || value; end
  def append(key, *values); ($settings[key] ||= []).concat(values); end

  def fetch(key, default = nil, &blk)
    if $settings.key?(key)
      v = $settings[key]
      v.respond_to?(:call) ? instance_exec(&v) : v
    elsif blk then blk.call
    else default
    end
  rescue StandardError
    default
  end

  # runtime DSL — no-ops at structure time, except we want `roles` non-empty so
  # the role-guard in the hook doesn't mask the deploy_mode logic we test, and
  # `invoke` records into $invoked.
  def on(*_); end
  def roles(*_); [:app]; end           # non-empty → role guard passes
  def execute(*_); end
  def run_locally(&_); end
  def invoke(name, *_); $invoked << name; end
  def info(*_); end
  def warn(*_); end
  def puts(*_); end                    # silence the hook's ℹ️ logging
  def upload!(*_); end
  def within(*_); end
  def test(*_); false; end
  def release_path; "/srv/app/current"; end
  def shared_path; "/srv/app/shared"; end
  def host; nil; end
end
include CapStub

module CapHooks
  def after(_event, name = nil, &blk); $after_hooks[name] = blk if blk; end
  def before(_event, _name = nil, &_blk); end
end
include CapHooks

# Load both rake files + their load:defaults so $settings is populated.
load PROXY_RAKE
load NUXT2_RAKE
Rake::Task["load:defaults"].invoke if Rake::Task.task_defined?("load:defaults")

# --- helpers ------------------------------------------------------------------
$failures = 0
def check(desc)
  ok = yield
  STDOUT.puts(ok ? "  ok   #{desc}" : "  FAIL #{desc}")
  $failures += 1 unless ok
rescue => e
  $failures += 1
  STDOUT.puts "  FAIL #{desc}  (#{e.class}: #{e.message})"
end

# Re-evaluate the proxy `nginx_app_hooks` default lambda under a given mode.
def app_hooks_default_for(mode)
  $settings[:nuxt3_deploy_mode] = mode
  fetch(:nginx_app_hooks)
end

# Run a captured after-hook body under a given mode, return what it invoked.
def run_hook(name, mode)
  $invoked = []
  $settings[:nuxt3_deploy_mode] = mode
  $after_hooks[name].call if $after_hooks[name]
  $invoked.dup
end

STDOUT.puts "G17 — proxy_nginx App-Nginx hook (port-collision guard):"

# Make sure the proxy hook + nuxt2 hook were actually captured.
check("update_nginx_configurations after-hook captured") { $after_hooks.key?(:update_nginx_configurations) }
check("rebuild_nuxt_app after-hook captured")           { $after_hooks.key?(:rebuild_nuxt_app) }

check(":ssr → nginx_app_hooks default is false (Zero-Config)") do
  app_hooks_default_for(:ssr) == false
end
check(":static → nginx_app_hooks default stays true") do
  app_hooks_default_for(:static) == true
end
check("unset (Rails/recipes2go proxy) → nginx_app_hooks default stays true") do
  $settings.delete(:nuxt3_deploy_mode)
  fetch(:nginx_app_hooks) == true
end

check(":ssr → App-Nginx hook does NOT invoke nginx:app:update") do
  !run_hook(:update_nginx_configurations, :ssr).include?("nginx:app:update")
end
check(":ssr → Proxy hook STILL runs (nginx:proxy:update invoked)") do
  run_hook(:update_nginx_configurations, :ssr).include?("nginx:proxy:update")
end
check(":static → App-Nginx hook DOES invoke nginx:app:update (unchanged)") do
  run_hook(:update_nginx_configurations, :static).include?("nginx:app:update")
end
check("unset (Rails proxy) → App-Nginx hook DOES invoke nginx:app:update (unchanged)") do
  run_hook(:update_nginx_configurations, nil).include?("nginx:app:update")
end
check(":ssr guard holds even if consumer force-sets nginx_app_hooks=true") do
  $settings[:nginx_app_hooks] = true
  res = run_hook(:update_nginx_configurations, :ssr)
  $settings.delete(:nginx_app_hooks)
  !res.include?("nginx:app:update")
end

STDOUT.puts "G18 — Nuxt2 nuxt.rake deploy:published rebuild hook:"

check(":ssr → Nuxt2 rebuild hook SKIPS nuxt:rebuild_app") do
  !run_hook(:rebuild_nuxt_app, :ssr).include?("nuxt:rebuild_app")
end
check(":static → Nuxt2 rebuild hook SKIPS nuxt:rebuild_app (nuxt3 owns it)") do
  !run_hook(:rebuild_nuxt_app, :static).include?("nuxt:rebuild_app")
end
check("unset (pure Nuxt2 deploy) → Nuxt2 rebuild hook RUNS nuxt:rebuild_app (unchanged)") do
  run_hook(:rebuild_nuxt_app, nil).include?("nuxt:rebuild_app")
end

STDOUT.puts
if $failures.zero?
  STDOUT.puts "ALL DEPLOY-MODE HOOK SMOKE CHECKS PASSED"
  exit 0
else
  STDOUT.puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
