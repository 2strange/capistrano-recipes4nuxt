# frozen_string_literal: true
#
# Standalone smoke for the Next / timers / postgres recipes (v1.2.0).
#
# Loads the three .rake files under a stubbed Capistrano DSL whose `on` YIELDS
# and whose `execute`/`upload!` RECORD what would run on the server — so we can
# check the rendered systemd units and the shell commands without a host.
#
# Run:  ruby test/next_timers_postgres_smoke_test.rb

require "rake"
require "stringio"

LIB_DIR = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(LIB_DIR) unless $LOAD_PATH.include?(LIB_DIR)

$settings = {}
$hooks = []
$executed = []
$uploads = {}
$upload_log = []  # every upload, in order (temp files share a path in the stub)
$test_results = {}   # command-substring => true/false for `test`
$captures = {}       # command-substring => output for `capture`

module CapStub
  def set(key, value = nil, &blk) = ($settings[key] = blk || value)
  def append(key, *values) = (($settings[key] ||= []).concat(values))

  def fetch(key, default = nil, &blk)
    if $settings.key?(key)
      v = $settings[key]
      v.respond_to?(:call) ? instance_exec(&v) : v
    elsif blk then blk.call
    else default
    end
  end

  def on(*_args) = yield
  def roles(*_args) = []
  def run_locally(&blk) = blk&.call
  def info(*_args); end
  def warn(*_args); end
  def puts(*_args); end
  def execute(*args) = ($executed << args.join(" "))
  def upload!(io, to) = (c = io.read; $upload_log << c; $uploads[to] = c)
  def capture(*args)
    cmd = args.join(" ")
    $captures.each { |k, v| return v if cmd.include?(k) }
    ""
  end
  def test(*args)
    cmd = args.join(" ")
    $test_results.each { |k, v| return v if cmd.include?(k) }
    false
  end
  def release_path = "/srv/mary/releases/20261015"
  def current_path = "/srv/mary/current"
  def shared_path = "/srv/mary/shared"
  def host = Struct.new(:user, :hostname).new("deploy", "mary-prod")
  def after(event, name = nil, &_blk) = ($hooks << [:after, event, name])
  def before(event, name = nil, &_blk) = ($hooks << [:before, event, name])
  def invoke(name, *args) = Rake::Task[name].reenable.then { Rake::Task[name].invoke(*args) }
end
include CapStub

%w[next timers postgres].each { |r| load File.expand_path("../lib/capistrano/tasks/#{r}.rake", __dir__) }
Rake::Task["load:defaults"].invoke

$failures = 0
def check(desc)
  ok = yield
  Kernel.puts(ok ? "  ok   #{desc}" : "  FAIL #{desc}")
  $failures += 1 unless ok
rescue => e
  $failures += 1
  Kernel.puts "  FAIL #{desc}  (#{e.class}: #{e.message})"
end
def reset! = ($executed.clear; $uploads.clear; $upload_log.clear)

set :application, "mary"
set :stage, "production"
set :user, "deploy"

Kernel.puts "Defaults (zero-config):"
check("next_app marker set") { fetch(:next_app) == true }
check("next binds 127.0.0.1:3500") { fetch(:next_host) == "127.0.0.1" && fetch(:next_port) == 3500 }
check("next.env is a linked file") { fetch(:linked_files).include?("config/next.env") }
check("node_modules is NOT a linked dir (per-release install)") { !Array(fetch(:linked_dirs)).include?("node_modules") }
check("postgres default: one owner role = db name → DATABASE_URL") do
  r = fetch(:postgres_db_roles)
  r.size == 1 && r[0][:name] == "mary_production" && r[0][:owner] && r[0][:env] == "DATABASE_URL"
end
check("no timers by default") { fetch(:systemd_timers) == [] }

Kernel.puts "Hooks:"
check("build in deploy:updated (before current switches)") { $hooks.include?([:after, :updated, :build_next_app]) }
check("restart in deploy:published") { $hooks.include?([:after, :published, :restart_next_app]) }
check("env upload before :starting") { $hooks.include?([:before, :starting, :upload_next_env]) }
check("timers set up in deploy:published") { $hooks.include?([:after, :published, :setup_app_timers]) }

# Mary-like configuration
set :next_use_nvm, true
set :next_nvm_version, "24.16.0"
set :next_secrets_dir, "config/secrets"
set :next_pre_publish_cmds, ["npx tsx scripts/migrate.ts"]
set :systemd_timers, [{ name: "purge", command: "npx tsx scripts/purge-expired.ts", on_calendar: "hourly", env: { "PURGE_ELEVENLABS" => "1" } }]
set :postgres_db_roles, [
  { name: "app_owner",   attributes: "BYPASSRLS",   env: "DATABASE_OWNER_URL", owner: true },
  { name: "app_user",    attributes: "NOBYPASSRLS", env: "DATABASE_URL" },
  { name: "app_service", attributes: "BYPASSRLS",   env: "DATABASE_SERVICE_URL" },
]
set :postgres_extensions, ["pgcrypto"]

Kernel.puts "next:build / pre_publish:"
reset!
invoke "next:build"
build = $executed.find { |c| c.include?("next build") }
check("build sources next.env + database.env") { build.include?("shared/config/next.env") && build.include?("shared/config/database.env") }
check("build uses nvm 24.16.0") { build.include?("nvm use 24.16.0") }
check("build runs in the release dir with pipefail") { build.include?("cd #{release_path}") && build.include?("pipefail") }
check("build does NOT source the secrets dir") { !build.include?("secrets") }
reset!
invoke "next:pre_publish"
check("pre_publish runs migrate in release") { $executed.any? { |c| c.include?("npx tsx scripts/migrate.ts") && c.include?("cd #{release_path}") } }
reset!
invoke "next:install_dependencies"
check("install without runtime ENV (keeps devDependencies)") { $executed.one? && !$executed[0].include?("next.env") }

Kernel.puts "next:setup_app / upload_env:"
reset!
invoke "next:setup_app"
check("next.env chmod 600") { $executed.include?("chmod 600 /srv/mary/shared/config/next.env") }
check("secrets dir chmod 700") { $executed.include?("chmod 700 /srv/mary/shared/config/secrets") }

Kernel.puts "next unit:"
reset!
invoke "next:configure"
unit = $uploads.values.first.to_s
check("WorkingDirectory = current") { unit.include?("WorkingDirectory=/srv/mary/current") }
check("next start with host/port") { unit.include?("next start -H 127.0.0.1 -p 3500") }
check("HOSTNAME env (Next reads HOSTNAME, not HOST)") { unit.include?("Environment=HOSTNAME=127.0.0.1") }
check("EnvironmentFile next.env then database.env") do
  i1 = unit.index("EnvironmentFile=-/srv/mary/shared/config/next.env")
  i2 = unit.index("EnvironmentFile=-/srv/mary/shared/config/database.env")
  i1 && i2 && i1 < i2
end
check("no secrets in unit") { !unit.match?(/PASSWORD|postgresql:\/\//) }

Kernel.puts "timers:"
reset!
$captures["ls "] = "/etc/systemd/system/mary_production_timer_purge.timer /etc/systemd/system/mary_production_timer_old.timer"
invoke "timers:setup"
svc = $uploads["/tmp/mary_production_timer_purge.service"].to_s
tim = $uploads["/tmp/mary_production_timer_purge.timer"].to_s
check("service: flock + command in current") { svc.include?("flock -n /srv/mary/shared/pids/mary_production_timer_purge.lock npx tsx scripts/purge-expired.ts") && svc.include?("WorkingDirectory=/srv/mary/current") }
check("service: per-timer env + app env files") { svc.include?("Environment=PURGE_ELEVENLABS=1") && svc.include?("EnvironmentFile=-/srv/mary/shared/config/database.env") }
check("service: nvm") { svc.include?("nvm use 24.16.0") }
check("timer: hourly, persistent") { tim.include?("OnCalendar=hourly") && tim.include?("Persistent=true") }
check("stale timer 'old' removed") { $executed.any? { |c| c.include?("disable --now mary_production_timer_old.timer") } }
check("purge timer enabled") { $executed.any? { |c| c.include?("enable --now mary_production_timer_purge.timer") } }
$captures.delete("ls ")
check("bad timer name rejected") do
  set :systemd_timers, [{ name: "Bad Name", command: "x" }]
  begin; invoke "timers:setup"; false; rescue RuntimeError; true; end
end
set :systemd_timers, []

Kernel.puts "postgres:setup (fresh cluster):"
reset!
invoke "postgres:setup"
sql = $upload_log.join
env = $uploads["/srv/mary/shared/config/database.env"].to_s
check("3 roles created with LOGIN + attributes") { %w[app_owner app_user app_service].all? { |r| sql.include?(%(CREATE ROLE "#{r}" LOGIN)) } && sql.include?("NOBYPASSRLS") }
check("database owned by app_owner, template0, C.UTF-8") { sql.include?(%(CREATE DATABASE "mary_production" OWNER "app_owner")) && sql.include?("template0") && sql.include?("C.UTF-8") }
check("pgcrypto extension") { sql.include?(%(CREATE EXTENSION IF NOT EXISTS "pgcrypto")) }
check("URLs mapped to env names") do
  env.match?(%r{^DATABASE_OWNER_URL=postgresql://app_owner:[0-9a-f]{48}@127\.0\.0\.1:5432/mary_production$}) &&
    env.match?(%r{^DATABASE_URL=postgresql://app_user:}) && env.match?(%r{^DATABASE_SERVICE_URL=postgresql://app_service:})
end
check("database.env chmod 600") { $executed.include?("chmod 600 /srv/mary/shared/config/database.env") }
check("no password on any command line") { $executed.none? { |c| c.match?(/PASSWORD|[0-9a-f]{48}/) } }

Kernel.puts "postgres:setup (foreign existing role):"
reset!
$test_results["database.env"] = false
$captures["from pg_roles where rolname='app_owner'"] = "1"
check("existing role without known URL aborts, no reset") do
  begin; invoke "postgres:setup"; false; rescue RuntimeError => e; e.message.include?("rotate_password") && !$upload_log.join.include?("ALTER ROLE"); end
end

Kernel.puts
if $failures.zero?
  Kernel.puts "ALL NEXT/TIMERS/POSTGRES SMOKE CHECKS PASSED"
  exit 0
else
  Kernel.puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
