require 'capistrano/recipes4nuxt/base_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers

namespace :load do
  task :defaults do

    set :nuxt3_stat_file,         -> { "_builded_app" }
    set :nuxt3_logs_file,         -> { "_builded_logs" }
    set :nuxt3_done_file,         -> { "_builded_frontend" }

    set :nuxt3_use_nvm,           -> { false }
    set :nuxt3_nvm_path,          -> { "~/.nvm" }
    set :nuxt3_nvm_version,       -> { "20.19.0" }
    set :nuxt3_nvm_script,        -> { "$HOME/.nvm/nvm.sh" }

    set :nuxt3_app_roles,         -> { :app }

    # Which deploy:published hook runs:
    #   :ssr    -> rebuild_app  (build + sync .output + restart Nitro service)  [App default]
    #   :static -> rebuild_static (generate + sync public, served by nginx)     [Website]
    set :nuxt3_deploy_mode,       -> { :ssr }

    # Nuxt 3 build output lives in `.output/` (not `dist/`):
    #   .output/server/index.mjs  -> Nitro SSR entrypoint
    #   .output/public/           -> static assets (also the `nuxt generate` result)
    set :nuxt3_build_dir,         -> { ".output" }
    # Shared dir the built `.output/` is rsynced into for the SSR service.
    set :nuxt3_output_folder,     -> { "output" }

    ## Maybe nonsense .. builds `APP_NAME_STG_DEPLOY_MODE`
    set :nuxt3_stage_env_var,     -> { build_deploy_env_var }

    # === Runtime ENV file (G1, Contract §4.2) ===
    # Per-instance ENV is uploaded from the consuming app and lives ONLY on the
    # server (gitignored locally). One code build → many instances, values at
    # runtime. Secrets/customer values belong here, NEVER in :nuxt3_ssr_env (repo).
    #   LOCAL  : config/nuxt_env/<stage>.env   (KEY=value per line, gitignored)
    #   SERVER : shared/config/nuxt3_ssr.env   (rsync target, linked_file, EnvironmentFile=-)
    set :nuxt3_ssr_env_file,      -> { "nuxt3_ssr.env" }
    set :nuxt3_ssr_env_local,     -> { "config/nuxt_env/#{fetch(:stage)}.env" }
    # Upload the ENV file automatically on `deploy:starting` (like keys:upload_config).
    set :nuxt3_ssr_upload_env_on_deploy, -> { true }

    # === Neutral deploy-mode var (G3/G12, Contract §4.3) ===
    # Replaces the old build_deploy_env_var (`APP_NAME_STG_DEPLOY_MODE`) construct.
    # Injected into the build AND sourced at runtime so prerendered pages and the
    # live service never diverge. ValidSlots maps SLOTS_DEPLOY_MODE onto this.
    set :nuxt3_app_env,           -> { fetch(:stage).to_s }

    # === Health-check (G5, Contract §5) ===
    set :nuxt3_ssr_verify_path,   -> { "/" }
    set :nuxt3_ssr_verify_retries, -> { 10 }
    set :nuxt3_ssr_verify_sleep,  -> { 2 }

    # === SSR (Nitro Node service) ===
    set :nuxt3_ssr_roles,         -> { :app }
    set :nuxt3_ssr_service_file,  -> { "#{fetch(:application)}_#{fetch(:stage)}_nuxt3_ssr" }
    set :nuxt3_ssr_service_old,   -> { "nuxt3_ssr_#{fetch(:application)}_#{fetch(:stage)}" }
    set :nuxt3_systemd_path,      -> { "/lib/systemd/system" }
    set :nuxt3_pid_path,          -> { "#{shared_path}/pids" }
    set :nuxt3_ssr_user,          -> { fetch(:user, 'deploy') }
    set :nuxt3_ssr_host,          -> { "127.0.0.1" }
    # PLACEHOLDER default – override per stage (analog :nginx_upstream_port).
    # Point the proxy here:  set :nginx_upstream_port, fetch(:nuxt3_ssr_port)
    set :nuxt3_ssr_port,          -> { 3500 }
    # Extra `Environment=` lines for the unit, e.g. { "API_BASE" => "https://..." }
    set :nuxt3_ssr_env,           -> { {} }
    set :nuxt3_ssr_log_lines,     -> { 100 }
    # Auto-restart the Nitro service from the deploy:published hook.
    # Set to `false` for the FIRST deploy (the systemd unit doesn't exist yet,
    # so a restart would fail) — deploy once, then `nuxt3:ssr:configure` to
    # create+enable+start the unit, then flip this back to `true`.
    set :nuxt3_ssr_hooks,         -> { true }

    # Static mode: run rebuild_static from the deploy:published hook.
    set :nuxt3_static_hooks,      -> { true }

    append :linked_files, fetch(:nuxt3_stat_file), fetch(:nuxt3_logs_file), fetch(:nuxt3_done_file)
    # Runtime ENV file lives under shared/config/ — linked so the release sees it too (G1).
    append :linked_files, "config/#{fetch(:nuxt3_ssr_env_file)}"
    append :linked_dirs, 'node_modules'

  end
end


namespace :nuxt3 do

  desc "output env var and stage"
  task :output_env do
    on roles(fetch(:nuxt3_app_roles)) do
      puts "🔧 Nuxt 3 stage: #{fetch(:stage)}"
      puts "🔧 Nuxt 3 NUXT_APP_ENV: #{fetch(:nuxt3_app_env)}"
      puts "🔧 Nuxt 3 legacy deploy-mode var (deprecated): #{fetch(:nuxt3_stage_env_var)}"
      puts "🔧 Nuxt 3 SSR upstream: #{fetch(:nuxt3_ssr_host)}:#{fetch(:nuxt3_ssr_port)}"
      puts "🔧 Nuxt 3 SSR ENV file: #{nuxt3_remote_env_file}"
    end
  end

  desc "Install dependencies"
  task :install_dependencies do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        write_nuxt3_state("installing")
        with_nuxt3_error_state("install_dependencies") do
          execute :rm, "-rf node_modules/*"
          execute :rm, "-rf #{shared_path}/node_modules/*"
          # npm ci wenn ein package-lock.json im Release liegt (exakter, deterministischer
          # Lockfile-Baum) — installiert jedes (genestete) Paket mit SEINEM passenden
          # Plattform-Binary und verhindert so esbuild/rollup "Expected X but got Y" beim
          # Hoisting divergierender Versionen. Sonst (kein Lockfile) npm install. Override
          # erzwingbar via set :nuxt3_npm_install_cmd, "ci"|"install".
          npm_cmd = fetch(:nuxt3_npm_install_cmd) do
            test("[ -f #{release_path}/package-lock.json ]") ? "ci" : "install"
          end
          if fetch(:nuxt3_use_nvm, false)
            env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
            execute %(bash -lc '#{nuxt3_nvm_prefix} && cd #{release_path} && env #{env_vars} npm #{npm_cmd}')
          else
            execute :npm, npm_cmd
          end
        end
      end
    end
  end


  desc "Build Nuxt 3 app (SSR → .output/server + .output/public)"
  task :build do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        write_nuxt3_state("building")
        log_file = "#{shared_path}/#{fetch(:nuxt3_logs_file)}"
        execute :echo, "'Deploy - Build - LOGS :: #{ Time.now.strftime("%d.%m.%Y - %H:%M") } ::' > #{log_file}"
        with_nuxt3_error_state("build") do
          if fetch(:nuxt3_use_nvm, false)
            env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
            # G3: source the runtime ENV file (build-ENV = runtime-ENV) + NUXT_APP_ENV,
            # and tee the build output into _builded_logs (was missing in the nvm branch).
            execute %(bash -lc '#{nuxt3_nvm_prefix} && #{nuxt3_build_env_source} && export #{nuxt3_app_env_assignment} && cd #{release_path} && env #{env_vars} ./node_modules/.bin/nuxt build 2>&1 | tee -a #{log_file}')
          else
            execute :npm, "run build 2>&1 | tee -a #{log_file}"
          end
        end
      end
    end
  end


  desc "Generate static Nuxt 3 site (prerender → .output/public)"
  task :generate do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        write_nuxt3_state("generating")
        log_file = "#{shared_path}/#{fetch(:nuxt3_logs_file)}"
        execute :echo, "'Deploy - Render - LOGS :: #{ Time.now.strftime("%d.%m.%Y - %H:%M") } ::' > #{log_file}"
        with_nuxt3_error_state("generate") do
          if fetch(:nuxt3_use_nvm, false)
            env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
            # G3: same single-source ENV + tee fix as :build (the nvm branch logged nothing before).
            execute %(bash -lc '#{nuxt3_nvm_prefix} && #{nuxt3_build_env_source} && export #{nuxt3_app_env_assignment} && cd #{release_path} && env #{env_vars} ./node_modules/.bin/nuxt generate 2>&1 | tee -a #{log_file}')
          else
            execute :npm, "run generate 2>&1 | tee -a #{log_file}"
          end
        end
      end
    end
  end


  desc "Sync full .output/ to shared (for SSR / Nitro service)"
  task :sync_output do
    on roles(fetch(:nuxt3_app_roles)) do
      write_nuxt3_state("syncing")
      with_nuxt3_error_state("sync_output") do
        execute :rsync, "-a --delete #{release_path}/#{fetch(:nuxt3_build_dir)}/ #{shared_path}/#{fetch(:nuxt3_output_folder)}/"
      end
      # NOTE: in the SSR path 'success' is written by ssr:restart AFTER the
      # service is healthy; here we only mark the sync done + touch the
      # "last build" marker. (Static path writes 'success' in sync_static.)
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_done_file)}"
    end
  end


  desc "Sync static .output/public/ to shared www (for nginx static serving)"
  task :sync_static do
    on roles(fetch(:nuxt3_app_roles)) do
      write_nuxt3_state("syncing")
      with_nuxt3_error_state("sync_static") do
        execute :rsync, "-a --delete #{release_path}/#{fetch(:nuxt3_build_dir)}/public/ #{shared_path}/www/"
      end
      # Static mode has no service to restart → the rsync IS the go-live.
      write_nuxt3_state("success")
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_done_file)}"
    end
  end


  desc "Fix permissions (just in case)"
  task :fix_permissions do
    on roles(fetch(:nuxt3_app_roles)) do
      execute :sudo, :chown, "-R #{fetch(:user)}:#{fetch(:user)} #{release_path}"
    end
  end


  desc "Setup defaults for Nuxt 3 app"
  task :setup_app do
    on roles(fetch(:nuxt3_app_roles)) do
      ensure_shared_www_path
      ensure_shared_log_path
      ensure_shared_output_path
      ensure_shared_pids_path
      ensure_shared_config_path
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_stat_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_logs_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_done_file)}"
      # Ensure the linked ENV file target exists so the symlink + EnvironmentFile=-
      # never dangle on a first deploy (empty file = zero-config-safe).
      execute :touch, nuxt3_remote_env_file
    end
  end


  desc "Install required node version with nvm"
  task :install_nvm_node do
    on roles(fetch(:nuxt3_app_roles)) do
      if fetch(:nuxt3_use_nvm, false)
        execute %(bash -lc 'source #{fetch(:nuxt3_nvm_script)} && nvm install #{fetch(:nuxt3_nvm_version)}')
      end
    end
  end


  desc "Rebuild Nuxt 3 SSR app (install → build → sync .output → restart service)"
  task :rebuild_app do
    invoke "nuxt3:install_dependencies"
    invoke "nuxt3:build"
    invoke "nuxt3:sync_output"
    invoke "nuxt3:ssr:restart"
  end

  desc "Rebuild static Nuxt 3 site (install → generate → sync public)"
  task :rebuild_static do
    invoke "nuxt3:install_dependencies"
    invoke "nuxt3:generate"
    invoke "nuxt3:sync_static"
  end

  desc "Regenerate static Nuxt 3 site (generate → sync public)"
  task :regenerate_app do
    invoke "nuxt3:generate"
    invoke "nuxt3:sync_static"
  end


  ## ── SSR Nitro Node service (mirrors recipes2go puma/sidekiq) ──
  namespace :ssr do

    def upload_nuxt3_ssr_service
      puts "📤 Uploading Nuxt 3 SSR systemd service..."
      ensure_shared_output_path
      ensure_shared_pids_path
      template2go("nuxt3_ssr_service", "/tmp/nuxt3_ssr.service")
      execute :sudo, :mv, "/tmp/nuxt3_ssr.service", "#{fetch(:nuxt3_systemd_path)}/#{fetch(:nuxt3_ssr_service_file)}.service"
      execute :sudo, "systemctl daemon-reload"
    end

    desc "Upload only the Nuxt 3 SSR systemd service file"
    task :upload_service do
      on roles fetch(:nuxt3_ssr_roles) do
        upload_nuxt3_ssr_service
      end
    end

    desc "Setup SSR service: upload unit (but don't enable yet)"
    task :setup do
      on roles fetch(:nuxt3_ssr_roles) do
        upload_nuxt3_ssr_service
        puts "✅ Nuxt 3 SSR service setup completed. Service is NOT yet enabled or started."
      end
    end

    desc "Activate and start the SSR service"
    task :activate do
      on roles fetch(:nuxt3_ssr_roles) do
        ensure_shared_pids_path
        invoke "nuxt3:ssr:enable"
        invoke "nuxt3:ssr:start"
        puts "✅ Nuxt 3 SSR service activated and running!"
      end
    end

    desc "Upload SSR service file, then enable it"
    task :configure do
      on roles fetch(:nuxt3_ssr_roles) do
        invoke "nuxt3:ssr:setup"
        invoke "nuxt3:ssr:activate"
        invoke "nuxt3:ssr:enable_if_needed"
        puts "✅ Nuxt 3 SSR service configured and enabled!"
      end
    end

    desc "Deploy SSR service (upload & start)"
    task :deploy do
      invoke "nuxt3:ssr:configure"
    end

    # `restart` is defined explicitly below (it writes the restarting|deploy
    # state + runs the health-check), so it is excluded from the generic loop.
    %w[start stop enable disable is-enabled].each do |command|
      desc "#{command.capitalize} Nuxt 3 SSR service"
      task command.gsub(/-/, '_') do
        on roles fetch(:nuxt3_ssr_roles) do
          ensure_shared_pids_path if %w[start enable].include?(command)
          execute :sudo, :systemctl, command, fetch(:nuxt3_ssr_service_file)
        end
      end
    end

    # === G1: per-instance runtime ENV file (Contract §4.2, keys-pattern) ===

    desc "Upload local config/nuxt_env/<stage>.env → shared/config/nuxt3_ssr.env"
    task :upload_env do
      on roles fetch(:nuxt3_ssr_roles) do
        local = fetch(:nuxt3_ssr_env_local)
        remote = nuxt3_remote_env_file
        ensure_shared_config_path
        unless File.exist?(local)
          # zero-config-safe: nothing to upload (EnvironmentFile=- tolerates a
          # missing/empty file). Warn, don't fail — matches keys:check_keys tone.
          # Touch the target anyway so the linked_file symlink + deploy:check
          # never dangle on a first deploy with no local ENV file.
          execute :touch, remote
          warn "⚠️  No local ENV file at #{local} — touched empty #{remote} (service uses unit ENV only)."
          next
        end
        puts "📤 Syncing SSR ENV: #{local} → #{remote}"
        remote_target = "#{host.user}@#{host.hostname}:#{remote}"
        run_locally { execute "rsync -av #{local} #{remote_target}" }
      end
    end

    desc "Warn if the SSR runtime ENV file is empty or missing"
    task :check_env do
      on roles fetch(:nuxt3_ssr_roles) do
        remote = nuxt3_remote_env_file
        if test("[ -s #{remote} ]")
          puts "✅ SSR ENV file present: #{remote}"
        else
          puts "⚠️  WARNING: SSR ENV file #{remote} is empty or missing!"
          puts "    Provide config/#{fetch(:nuxt3_ssr_env_local).split('/').last} locally and run nuxt3:ssr:upload_env,"
          puts "    or rely on unit Environment= lines only (NUXT_PUBLIC_*/secrets won't be set)."
        end
      end
    end

    # === G5: health-check after restart (Contract §5) ===

    desc "Health-check the Nitro SSR service (curl 127.0.0.1:<port> with retry)"
    task :verify do
      on roles fetch(:nuxt3_ssr_roles) do
        url = "http://#{fetch(:nuxt3_ssr_host)}:#{fetch(:nuxt3_ssr_port)}#{fetch(:nuxt3_ssr_verify_path)}"
        retries = fetch(:nuxt3_ssr_verify_retries).to_i
        pause = fetch(:nuxt3_ssr_verify_sleep).to_i
        info "🩺 Verifying SSR service at #{url} (#{retries} tries, #{pause}s apart)…"
        ok = false
        retries.times do |i|
          # -sf: silent + fail (non-2xx ⇒ non-zero exit); -o /dev/null: drop body;
          # --max-time guards against a hung socket. `test` swallows the non-zero.
          if test("curl -sf -o /dev/null --max-time 5 #{url}")
            ok = true
            info "✅ SSR service healthy after #{i + 1} attempt(s)."
            break
          end
          sleep pause
        end
        unless ok
          write_nuxt3_state("ERROR-verify")
          execute :sudo, "journalctl -u #{fetch(:nuxt3_ssr_service_file)} -rn 40 --no-pager || true"
          raise "❌ SSR health-check failed: #{url} did not respond OK after #{retries} attempts."
        end
      end
    end

    # === G2 + G4 + G5: restart with state + first-deploy autodetect + verify ===

    desc "Restart the Nitro SSR service (autodetect first deploy, write state, verify)"
    task :restart do
      on roles fetch(:nuxt3_ssr_roles) do
        ensure_shared_pids_path
        # G4: first-deploy ergonomics — if the unit doesn't exist yet, configure
        # it (upload + enable + start) instead of restarting a non-existent unit.
        # Removes the old `nuxt3_ssr_hooks=false` dance for the very first deploy.
        unless test("systemctl cat #{fetch(:nuxt3_ssr_service_file)} > /dev/null 2>&1")
          info "ℹ️  systemd unit #{fetch(:nuxt3_ssr_service_file)} not found — running ssr:configure (first deploy)."
          invoke "nuxt3:ssr:configure"
        else
          write_nuxt3_state("restarting")
          execute :sudo, :systemctl, "restart", fetch(:nuxt3_ssr_service_file)
        end
      end
      # G5: health-check after (re)start — fail loudly instead of silently broken.
      invoke "nuxt3:ssr:verify"
      # Only now is the deploy truly live → write success.
      on roles fetch(:nuxt3_ssr_roles) do
        write_nuxt3_state("success")
      end
    end

    desc "Enable SSR service if it's not already enabled"
    task :enable_if_needed do
      on roles fetch(:nuxt3_ssr_roles) do
        if test("systemctl is-enabled #{fetch(:nuxt3_ssr_service_file)} || echo disabled") == "disabled"
          info "🔧 Enabling #{fetch(:nuxt3_ssr_service_file)} service..."
          execute :sudo, "systemctl enable --now #{fetch(:nuxt3_ssr_service_file)}"
        else
          info "✅ #{fetch(:nuxt3_ssr_service_file)} is already enabled, skipping."
        end
      end
    end

    desc "Remove old-style SSR service files (nuxt3_ssr_APP_NAME)"
    task :remove_old_services do
      on roles fetch(:nuxt3_ssr_roles) do
        old_service_file = fetch(:nuxt3_ssr_service_old)
        old_path = "/etc/systemd/system"
        remove_app_service("Nuxt 3 SSR", fetch(:nuxt3_systemd_path), old_service_file)
        remove_app_service("Nuxt 3 SSR", old_path, old_service_file)
        remove_app_service("Nuxt 3 SSR", old_path, fetch(:nuxt3_ssr_service_file))
      end
    end

    desc "Check SSR service status"
    task :check_status do
      on roles fetch(:nuxt3_ssr_roles) do
        execute :sudo, "systemctl status #{fetch(:nuxt3_ssr_service_file)} --no-pager"
      end
    end

    desc "Get logs for the SSR service"
    task :logs do
      on roles fetch(:nuxt3_ssr_roles) do
        execute :sudo, "journalctl -u #{fetch(:nuxt3_ssr_service_file)} -rn #{fetch(:nuxt3_ssr_log_lines, 100)}"
      end
    end

  end

end

namespace :deploy do
  # G1: keep the per-instance runtime ENV file fresh on every deploy (like
  # keys:upload_config). Opt-out via `set :nuxt3_ssr_upload_env_on_deploy, false`.
  before :starting, :upload_nuxt3_ssr_env do
    if fetch(:nuxt3_deploy_mode) != :static && fetch(:nuxt3_ssr_upload_env_on_deploy)
      invoke "nuxt3:ssr:upload_env"
    end
  end

  after 'deploy:published', :rebuild_nuxt3_app do
    if fetch(:nuxt3_deploy_mode) == :static
      # Static: no node service, so the build+sync is the whole story.
      invoke "nuxt3:rebuild_static" if fetch(:nuxt3_static_hooks)
    else
      # SSR: build+sync .output, then restart the Nitro service. Since G4,
      # ssr:restart AUTODETECTS a missing unit and runs ssr:configure on the
      # first deploy, so the old `nuxt3_ssr_hooks=false` first-deploy dance is
      # no longer required. The flag is kept ONLY as an escape hatch to skip the
      # restart entirely (e.g. build-only on a host where the service is managed
      # out-of-band). Same hook position as puma/sidekiq.
      if fetch(:nuxt3_ssr_hooks)
        invoke "nuxt3:rebuild_app"
      else
        invoke "nuxt3:install_dependencies"
        invoke "nuxt3:build"
        invoke "nuxt3:sync_output"
      end
    end
  end
end


desc 'Server setup tasks'
task :setup do
  invoke 'nuxt3:setup_app'
  # G1: seed the runtime ENV file at setup time (no-op-safe if absent locally).
  invoke 'nuxt3:ssr:upload_env' if fetch(:nuxt3_deploy_mode) != :static
end
