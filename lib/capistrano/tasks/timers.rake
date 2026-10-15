require 'capistrano/recipes4nuxt/base_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers

# Generic systemd timers for recurring app jobs (cron replacement).
#
#   Capfile:  require "capistrano/recipes4nuxt/timers"
#
#   set :systemd_timers, [
#     { name: "purge", command: "npx tsx scripts/purge-expired.ts",
#       on_calendar: "hourly", env: { "PURGE_ELEVENLABS" => "1" } },
#   ]
#
# Per timer: name (required, [a-z0-9_-]), command (required, runs in current/ via
# bash -lc — no single quotes inside), on_calendar (systemd OnCalendar, default
# "hourly"), flock (default true: a still-running job skips the next tick),
# env (non-secret Environment= lines), nvm (default :timers_use_nvm).
#
# Jobs see the same ENV files as the app (next.env + postgres URLs) when the
# next recipe is loaded; override via :timers_env_files.
#
# Framework-agnostic on purpose (Next, Nuxt, Rails). Lives in recipes4nuxt for
# now; port to recipes2go when a Rails app needs it (Austin 2026-10-15).

namespace :load do
  task :defaults do
    set :timers_roles,       -> { :app }
    set :systemd_timers,     -> { [] }
    set :timers_prefix,      -> { "#{fetch(:application)}_#{fetch(:stage)}_timer" }
    set :timers_systemd_path, -> { "/etc/systemd/system" }
    set :timers_user,        -> { fetch(:user, 'deploy') }
    set :timers_workdir,     -> { current_path }
    set :timers_use_nvm,     -> { fetch(:next_use_nvm, fetch(:nuxt3_use_nvm, false)) }
    set :timers_nvm_version, -> { fetch(:next_nvm_version, fetch(:nuxt3_nvm_version, "24")) }
    set :timers_nvm_script,  -> { "$HOME/.nvm/nvm.sh" }
    set :timers_env_files,   -> { fetch(:next_app, false) ? next_all_env_files : [] }
    set :timers_hooks,       -> { true }
  end
end

namespace :timers do

  def timers_normalized
    Array(fetch(:systemd_timers)).map do |t|
      t = t.transform_keys(&:to_sym)
      raise "❌ systemd_timers: every timer needs :name and :command (#{t.inspect})" unless t[:name] && t[:command]
      raise "❌ systemd_timers: name '#{t[:name]}' must match [a-z0-9_-]+" unless t[:name].to_s =~ /\A[a-z0-9_-]+\z/
      raise "❌ systemd_timers: command for '#{t[:name]}' must not contain single quotes" if t[:command].include?("'")
      {
        name: t[:name].to_s,
        unit: "#{fetch(:timers_prefix)}_#{t[:name]}",
        command: t[:command],
        on_calendar: t[:on_calendar] || "hourly",
        flock: t.fetch(:flock, true),
        env: t[:env] || {},
        nvm: t.fetch(:nvm, fetch(:timers_use_nvm)),
      }
    end
  end

  def timer_exec_line(t)
    parts = []
    parts << "source #{fetch(:timers_nvm_script)} && nvm use #{fetch(:timers_nvm_version)} >/dev/null" if t[:nvm]
    cmd = t[:flock] ? "flock -n #{shared_path}/pids/#{t[:unit]}.lock #{t[:command]}" : t[:command]
    parts << "exec #{cmd}"
    "/bin/bash -lc '#{parts.join(' && ')}'"
  end

  desc "Upload + enable all :systemd_timers, remove timers no longer listed"
  task :setup do
    on roles(fetch(:timers_roles)) do
      ensure_shared_pids_path
      path = fetch(:timers_systemd_path)
      wanted = timers_normalized
      wanted.each do |t|
        @timer = t
        @timer_exec = timer_exec_line(t)
        %w[service timer].each do |type|
          template2go("app_timer_#{type}", "/tmp/#{t[:unit]}.#{type}")
          execute :sudo, :mv, "/tmp/#{t[:unit]}.#{type}", "#{path}/#{t[:unit]}.#{type}"
        end
        info "⏱  #{t[:unit]}: #{t[:on_calendar]} → #{t[:command]}"
      end
      # Stale timers of THIS app/stage (same prefix, not listed anymore) → remove.
      existing = capture(:ls, "#{path}/#{fetch(:timers_prefix)}_*.timer", "2>/dev/null || true").split
      stale = existing.map { |f| File.basename(f, ".timer") } - wanted.map { |t| t[:unit] }
      stale.each do |unit|
        info "🗑  removing stale timer #{unit}"
        execute :sudo, "systemctl disable --now #{unit}.timer || true"
        execute :sudo, :rm, "-f", "#{path}/#{unit}.timer", "#{path}/#{unit}.service"
      end
      execute :sudo, "systemctl daemon-reload"
      wanted.each { |t| execute :sudo, "systemctl enable --now #{t[:unit]}.timer" }
    end
  end

  desc "List this app's timers (next/last run)"
  task :list do
    on roles(fetch(:timers_roles)) do
      puts capture(:systemctl, "list-timers --all --no-pager '#{fetch(:timers_prefix)}_*' || true")
    end
  end

  desc "Run one timer's job now: cap <stage> timers:run[name]"
  task :run, :name do |_t, args|
    on roles(fetch(:timers_roles)) do
      execute :sudo, "systemctl start #{fetch(:timers_prefix)}_#{args[:name]}.service"
    end
  end

  desc "Journal of one timer's job: cap <stage> timers:logs[name]"
  task :logs, :name do |_t, args|
    on roles(fetch(:timers_roles)) do
      puts capture(:sudo, "journalctl -u #{fetch(:timers_prefix)}_#{args[:name]}.service -n 100 --no-pager")
    end
  end

end

namespace :deploy do
  after :published, :setup_app_timers do
    invoke "timers:setup" if fetch(:timers_hooks) && !Array(fetch(:systemd_timers)).empty?
  end
end
