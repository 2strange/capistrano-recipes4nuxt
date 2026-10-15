require 'capistrano/recipes4nuxt/base_helpers'
require 'capistrano/recipes4nuxt/next_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers
include Capistrano::Recipes4nuxt::NextHelpers

# Next.js (App Router / `next start`) deploy recipe.
#
#   Capfile:  require "capistrano/recipes4nuxt/next"
#             require "capistrano/recipes4nuxt/proxy_nginx"   # optional, proxy + certbot
#
# ⚠️ Do NOT also `require "capistrano/recipes4nuxt"` (Nuxt 2) or `.../nuxt3` in the
#    same Capfile — those bring their own build hooks + a shared node_modules.
#
# Flow per deploy (atomic — a red build never goes live):
#   deploy:starting   → next:upload_env           (config/next_env/<stage>.env → shared/config/next.env, 0600)
#   deploy:updated    → next:install_dependencies (npm ci, per release — NOT a shared node_modules,
#                        the running release keeps its own deps while the new one builds)
#                     → next:build                (next build, runtime ENV sourced: NEXT_PUBLIC_* is baked in here)
#                     → next:pre_publish          (:next_pre_publish_cmds, e.g. migrations)
#   deploy:published  → next:restart              (first deploy: upload + enable unit) → next:verify (curl)
#
# Rollback (`cap <stage> deploy:rollback`) re-points `current` and restarts — the
# old release still has its own node_modules + .next, no rebuild needed.

namespace :load do
  task :defaults do

    # Marker for other recipes (proxy_nginx G17 guard, nuxt2 hook) — a node
    # service runs on :next_port, there is no App-Nginx.
    set :next_app,                -> { true }

    set :next_roles,              -> { :app }

    set :next_use_nvm,            -> { false }
    set :next_nvm_version,        -> { "24" }
    set :next_nvm_script,         -> { "$HOME/.nvm/nvm.sh" }

    # nil = auto: `ci` when package-lock.json exists, else `install`.
    set :next_npm_install_cmd,    -> { nil }
    set :next_build_cmd,          -> { "./node_modules/.bin/next build" }
    # Extra args appended to `next start -H <host> -p <port>`.
    set :next_start_args,         -> { "" }

    # Commands run in the NEW release after the build, BEFORE `current` switches
    # (nvm + runtime ENV loaded). A failing command aborts the deploy; the old
    # release keeps running. e.g. ["npx tsx scripts/migrate.ts"]
    set :next_pre_publish_cmds,   -> { [] }

    # === Runtime ENV ===
    #   LOCAL  : config/next_env/<stage>.env   (KEY=value per line, gitignored)
    #   SERVER : shared/config/next.env        (0600, EnvironmentFile=-, also sourced for the build)
    set :next_env_file,           -> { "next.env" }
    set :next_env_local,          -> { "config/next_env/#{fetch(:stage)}.env" }
    set :next_upload_env_on_deploy, -> { true }
    # Further ENV files (relative to shared_path or absolute), loaded after next.env.
    set :next_extra_env_files,    -> { [] }
    # Non-secret `Environment=` lines for the unit (the unit file is world-readable!).
    set :next_env,                -> { {} }

    # Optional secrets dir (relative to shared_path), created 0700 on setup.
    # The gem never writes into it — put one file per key there yourself (0600)
    # and point the app at it, e.g. SECRETS_DIR=<shared>/config/secrets in next.env.
    set :next_secrets_dir,        -> { nil }

    # === Service ===
    set :next_service_file,       -> { "#{fetch(:application)}_#{fetch(:stage)}_next" }
    set :next_systemd_path,       -> { "/lib/systemd/system" }
    set :next_user,               -> { fetch(:user, 'deploy') }
    # Bind host: 127.0.0.1 = proxy on the same box (safe default).
    # Cross-host proxy → "0.0.0.0"; then the port must be reachable ONLY by the
    # proxy (tailnet-only box or firewall — operator/infra, T4). Same as nuxt3 G16.
    set :next_host,               -> { "127.0.0.1" }
    # Unique per instance on a shared box. Point the proxy here (nginx_upstream_port).
    set :next_port,               -> { 3500 }
    set :next_hooks,              -> { true }

    # === Health-check ===
    set :next_verify_path,        -> { "/" }
    set :next_verify_retries,     -> { 15 }
    set :next_verify_sleep,       -> { 2 }
    set :next_healthcheck_host,   -> { "127.0.0.1" }

    set :next_build_log,          -> { "log/next_build.log" }

    append :linked_files, "config/#{fetch(:next_env_file)}"
    append :linked_dirs, "log"

  end
end


namespace :next do

  desc "Print the Next.js deploy settings"
  task :output_env do
    on roles(fetch(:next_roles)) do
      puts "🔧 Next stage:       #{fetch(:stage)}"
      puts "🔧 Next bind:        #{fetch(:next_host)}:#{fetch(:next_port)}"
      puts "🔧 Next service:     #{fetch(:next_service_file)}"
      puts "🔧 Next ENV files:   #{next_all_env_files.join(', ')}"
      puts "🔧 Next secrets dir: #{next_secrets_path || '(none)'}"
      if fetch(:next_host).to_s != "127.0.0.1"
        puts "⚠️  Next binds non-loopback (#{fetch(:next_host)}) — port #{fetch(:next_port)} must be reachable ONLY by the proxy (tailnet/firewall = operator, T4)."
      end
    end
  end

  desc "Refuse to deploy when a Nuxt recipe is loaded in the same Capfile"
  task :check_recipes do
    clashing = %w[nuxt:rebuild_app nuxt3:rebuild_app].select { |t| Rake::Task.task_defined?(t) }
    unless clashing.empty?
      raise "❌ next recipe + Nuxt recipe (#{clashing.join(', ')}) in one Capfile — they bring competing build hooks. Require only capistrano/recipes4nuxt/next (+ proxy_nginx/certbot)."
    end
  end

  desc "Create shared dirs, empty next.env (0600) and the optional secrets dir (0700)"
  task :setup_app do
    on roles(fetch(:next_roles)) do
      ensure_shared_config_path
      ensure_shared_log_path
      ensure_shared_pids_path
      env = next_env_remote
      execute :touch, env
      execute :chmod, "600", env
      if (dir = next_secrets_path)
        execute :mkdir, "-p", dir
        execute :chmod, "700", dir
        puts "🔐 Secrets dir ready: #{dir} (0700) — add one file per key yourself (chmod 600)."
      end
    end
  end

  desc "Upload local config/next_env/<stage>.env → shared/config/next.env (0600)"
  task :upload_env do
    on roles(fetch(:next_roles)) do
      local = fetch(:next_env_local)
      remote = next_env_remote
      ensure_shared_config_path
      unless File.exist?(local)
        execute :touch, remote
        execute :chmod, "600", remote
        warn "⚠️  No local ENV file at #{local} — kept/created #{remote} as is."
        next
      end
      puts "📤 Syncing Next ENV: #{local} → #{remote}"
      remote_target = "#{host.user}@#{host.hostname}:#{remote}"
      run_locally { execute "rsync -av --chmod=F600 #{local} #{remote_target}" }
      execute :chmod, "600", remote
    end
  end

  desc "Warn about empty ENV file and NEXT_PUBLIC_* names that look like secrets"
  task :check_env do
    on roles(fetch(:next_roles)) do
      remote = next_env_remote
      unless test("[ -s #{remote} ]")
        puts "⚠️  #{remote} is empty or missing — provide #{fetch(:next_env_local)} and run next:upload_env."
        next
      end
      # NEXT_PUBLIC_* is inlined into the browser bundle at build time → public.
      suspicious = capture(:grep, "-oE", "'^NEXT_PUBLIC_[A-Z0-9_]*(KEY|SECRET|TOKEN|PASS|PASSWORD)[A-Z0-9_]*='", remote, "|| true")
      unless suspicious.strip.empty?
        puts "⚠️  These NEXT_PUBLIC_* vars look like secrets and end up in the browser bundle:"
        puts suspicious.lines.map { |l| "    #{l.strip.chomp('=')}" }.join("\n")
      end
    end
  end

  desc "Install dependencies in the release (npm ci, per release)"
  task :install_dependencies do
    on roles(fetch(:next_roles)) do
      npm_cmd = fetch(:next_npm_install_cmd) || (test("[ -f #{release_path}/package-lock.json ]") ? "ci" : "install")
      # No runtime ENV here: NODE_ENV=production would drop the devDependencies the build needs.
      execute next_shell("npm #{npm_cmd}", with_env: false)
    end
  end

  desc "Build the Next.js app in the release (runtime ENV sourced)"
  task :build do
    on roles(fetch(:next_roles)) do
      log_file = "#{shared_path}/#{fetch(:next_build_log)}"
      execute :echo, "'Next build :: #{Time.now.strftime('%d.%m.%Y - %H:%M')} ::' > #{log_file}"
      # pipefail: a failing build must fail the deploy despite the tee.
      execute next_shell("set -o pipefail; #{fetch(:next_build_cmd)} 2>&1 | tee -a #{log_file}")
    end
  end

  desc "Run :next_pre_publish_cmds in the new release (before current switches)"
  task :pre_publish do
    cmds = Array(fetch(:next_pre_publish_cmds))
    next if cmds.empty?
    on roles(fetch(:next_roles)) do
      cmds.each do |cmd|
        info "▶️  pre_publish: #{cmd}"
        execute next_shell(cmd)
      end
    end
  end

  desc "Install the requested node version with nvm"
  task :install_nvm_node do
    on roles(fetch(:next_roles)) do
      if fetch(:next_use_nvm, false)
        execute %(bash -lc 'source #{fetch(:next_nvm_script)} && nvm install #{fetch(:next_nvm_version)}')
      end
    end
  end

  def upload_next_service
    puts "📤 Uploading Next systemd service..."
    ensure_shared_pids_path
    template2go("next_service", "/tmp/#{fetch(:next_service_file)}.service")
    execute :sudo, :mv, "/tmp/#{fetch(:next_service_file)}.service", "#{fetch(:next_systemd_path)}/#{fetch(:next_service_file)}.service"
    execute :sudo, "systemctl daemon-reload"
  end

  desc "Upload the systemd unit (does not start it)"
  task :upload_service do
    on roles(fetch(:next_roles)) { upload_next_service }
  end

  desc "Upload unit, enable + start it"
  task :configure do
    on roles(fetch(:next_roles)) do
      upload_next_service
      execute :sudo, "systemctl enable --now #{fetch(:next_service_file)}"
      puts "✅ Next service configured and running."
    end
  end

  %w[start stop status].each do |command|
    desc "#{command.capitalize} the Next service"
    task command do
      on roles(fetch(:next_roles)) do
        execute :sudo, :systemctl, command, fetch(:next_service_file), *(command == "status" ? ["--no-pager"] : [])
      end
    end
  end

  desc "Show the last 100 journal lines of the Next service"
  task :logs do
    on roles(fetch(:next_roles)) do
      puts capture(:sudo, "journalctl -u #{fetch(:next_service_file)} -n 100 --no-pager")
    end
  end

  desc "Health-check the Next service (curl with retry)"
  task :verify do
    on roles(fetch(:next_roles)) do
      url = "http://#{fetch(:next_healthcheck_host)}:#{fetch(:next_port)}#{fetch(:next_verify_path)}"
      retries = fetch(:next_verify_retries).to_i
      pause = fetch(:next_verify_sleep).to_i
      info "🩺 Verifying Next at #{url} (#{retries} tries, #{pause}s apart)…"
      ok = retries.times.any? do |i|
        if test("curl -sf -o /dev/null --max-time 5 #{url}")
          info "✅ Next healthy after #{i + 1} attempt(s)."
          true
        else
          sleep pause
          false
        end
      end
      unless ok
        execute :sudo, "journalctl -u #{fetch(:next_service_file)} -rn 40 --no-pager || true"
        raise "❌ Next health-check failed: #{url} did not respond OK after #{retries} attempts."
      end
    end
  end

  desc "Restart the Next service (first deploy: configure), then verify"
  task :restart do
    on roles(fetch(:next_roles)) do
      if test("systemctl cat #{fetch(:next_service_file)} > /dev/null 2>&1")
        # Re-upload so changed settings (port, env files) reach the unit.
        upload_next_service
        execute :sudo, :systemctl, "restart", fetch(:next_service_file)
      else
        info "ℹ️  systemd unit #{fetch(:next_service_file)} not found — configuring (first deploy)."
        invoke "next:configure"
      end
    end
    invoke "next:verify"
  end

end


namespace :deploy do
  before :starting, :next_check_recipes do
    invoke "next:check_recipes"
  end

  before :starting, :upload_next_env do
    invoke "next:upload_env" if fetch(:next_upload_env_on_deploy)
  end

  after :updated, :build_next_app do
    invoke "next:install_dependencies"
    invoke "next:build"
    invoke "next:pre_publish"
  end

  after :published, :restart_next_app do
    invoke "next:restart" if fetch(:next_hooks)
  end
end


desc 'Server setup tasks'
task :setup do
  invoke 'next:setup_app'
  invoke 'next:upload_env'
end
