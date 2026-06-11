# frozen_string_literal: true
#
# Standalone wiring-smoke for lib/capistrano/tasks/nuxt3.rake.
#
# G9-prep (Etappe 1): loads the .rake file into a *minimal stubbed* Capistrano
# DSL (Rake + a fake `on/roles/execute/set/fetch/...`) so we can assert the new
# Etappe-1 tasks are defined and the deploy hooks are registered — WITHOUT a
# real Capistrano install, SSHKit, or a live server.
#
# Run:  ruby test/nuxt3_tasks_wiring_test.rb
#
# This is a structural check (do the tasks/hooks exist, are the helpers wired);
# behavioural execution against a real host is the deploy-verify step (Robert).

require "rake"

LIB_DIR   = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(LIB_DIR) unless $LOAD_PATH.include?(LIB_DIR)

RAKE_FILE = File.expand_path("../lib/capistrano/tasks/nuxt3.rake", __dir__)

# --- stub the Capistrano DSL the rake file calls at *load* time --------------
# We only need load-time methods (set/append/fetch/namespace/task/desc/after/
# before/Rake::Task) to resolve. Task *bodies* are not executed here.

$settings = {}
$before_hooks = []
$after_hooks = []

module CapStub
  def set(key, value = nil, &blk)
    $settings[key] = blk || value
  end

  def append(key, *values)
    ($settings[key] ||= []).concat(values)
  end

  # fetch resolves lambdas lazily, mimicking Capistrano. Guarded against
  # infinite recursion / missing deps by rescuing and returning the default.
  def fetch(key, default = nil, &blk)
    if $settings.key?(key)
      v = $settings[key]
      v.respond_to?(:call) ? instance_exec(&v) : v
    elsif blk
      blk.call
    else
      default
    end
  rescue StandardError
    default
  end

  # Capistrano runtime-only DSL — no-ops at load/structure time.
  def on(*_args); end
  def roles(*_args); []; end
  def execute(*_args); end
  def run_locally(&_blk); end
  def invoke(*_args); end
  def info(*_args); end
  def warn(*_args); end
  def upload!(*_args); end
  def within(*_args); end
  def test(*_args); false; end
  def release_path; "/srv/app/current"; end
  def shared_path; "/srv/app/shared"; end
  def host; nil; end
end

# Provide the stub on the top-level (rake files run at top-level `self`).
include CapStub

# The rake file does `require 'capistrano/recipes4nuxt/base_helpers'` itself
# (lib/ is on $LOAD_PATH), loading the REAL helpers — we exercise their methods.

# Capistrano provides `Rake::Task[...].enhance`; vanilla Rake has it too. Good.
# Some recipes2go files call this; nuxt3.rake uses plain after/before via the
# capistrano DSL methods, which we map onto records below.
module CapHooks
  def after(event, name = nil, &blk)
    $after_hooks << [event, name]
  end

  def before(event, name = nil, &blk)
    $before_hooks << [event, name]
  end
end
include CapHooks

# Load the rake file under our stubbed DSL.
load RAKE_FILE

# Resolve the `load:defaults` task body so the `set`/`append` calls run and
# populate $settings (that's where the new config vars live).
Rake::Task["load:defaults"].invoke if Rake::Task.task_defined?("load:defaults")

# --- assertions ---------------------------------------------------------------
$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  ok   #{desc}" : "  FAIL #{desc}")
  $failures += 1 unless ok
rescue => e
  $failures += 1
  puts "  FAIL #{desc}  (#{e.class}: #{e.message})"
end

def task?(name)
  Rake::Task.task_defined?(name)
end

puts "Tasks defined:"
%w[
  nuxt3:ssr:upload_env
  nuxt3:ssr:check_env
  nuxt3:ssr:verify
  nuxt3:ssr:restart
  nuxt3:ssr:configure
  nuxt3:install_dependencies
  nuxt3:build
  nuxt3:sync_output
].each do |t|
  check("task #{t} exists") { task?(t) }
end

puts "Config defaults (G1/G3/G5/G12):"
check("nuxt3_ssr_env_file default = nuxt3_ssr.env") do
  fetch(:nuxt3_ssr_env_file) == "nuxt3_ssr.env"
end
check("nuxt3_ssr_env_local default = config/nuxt_env/<stage>.env") do
  $settings.key?(:nuxt3_ssr_env_local)
end
check("nuxt3_app_env default present (NUXT_APP_ENV source)") do
  $settings.key?(:nuxt3_app_env)
end
check("nuxt3_ssr_verify_retries default present") do
  $settings.key?(:nuxt3_ssr_verify_retries)
end
check("nuxt3_ssr_host default = 127.0.0.1 (single-host safe default, G16)") do
  fetch(:nuxt3_ssr_host) == "127.0.0.1"
end
check("nuxt3_ssr_healthcheck_host default = 127.0.0.1 (decoupled from bind, G16)") do
  fetch(:nuxt3_ssr_healthcheck_host) == "127.0.0.1"
end
check("nuxt3_ssr_upload_env_on_deploy default present") do
  $settings.key?(:nuxt3_ssr_upload_env_on_deploy)
end
check("ENV file appended to linked_files") do
  (fetch(:linked_files) || []).any? { |f| f.to_s.include?("nuxt3_ssr.env") }
end

puts "Deploy hooks (G1):"
check("before :starting upload_nuxt3_ssr_env registered") do
  $before_hooks.any? { |ev, name| ev == :starting && name == :upload_nuxt3_ssr_env }
end
check("after deploy:published rebuild hook still registered") do
  $after_hooks.any? { |ev, _| ev.to_s == "deploy:published" }
end

puts "Helper methods (G2/G3):"
check("write_nuxt3_state helper defined") { respond_to?(:write_nuxt3_state) }
check("with_nuxt3_error_state helper defined") { respond_to?(:with_nuxt3_error_state) }
check("nuxt3_build_env_source helper defined") { respond_to?(:nuxt3_build_env_source) }
check("ensure_shared_config_path helper defined") { respond_to?(:ensure_shared_config_path) }
check("nuxt3_build_env_source guards a missing file ([ -f ... ])") do
  $settings[:nuxt3_ssr_env_file] = "nuxt3_ssr.env"
  src = nuxt3_build_env_source
  src.include?("set -a") && src.include?("[ -f ") && src.include?("set +a")
end

puts
if $failures.zero?
  puts "ALL TASK-WIRING SMOKE CHECKS PASSED"
  exit 0
else
  puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
