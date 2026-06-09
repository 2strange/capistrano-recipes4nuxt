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
    append :linked_dirs, 'node_modules'

  end
end


namespace :nuxt3 do

  desc "output env var and stage"
  task :output_env do
    on roles(fetch(:nuxt3_app_roles)) do
      puts "🔧 Nuxt 3 stage: #{fetch(:stage)}"
      puts "🔧 Nuxt 3 deploy mode: #{fetch(:nuxt3_stage_env_var)}"
      puts "🔧 Nuxt 3 SSR upstream: #{fetch(:nuxt3_ssr_host)}:#{fetch(:nuxt3_ssr_port)}"
    end
  end

  desc "Install dependencies"
  task :install_dependencies do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        execute :echo, "'installing|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
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


  desc "Build Nuxt 3 app (SSR → .output/server + .output/public)"
  task :build do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        execute :echo, "'building|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
        if fetch(:nuxt3_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          execute %(bash -lc '#{nuxt3_nvm_prefix} && cd #{release_path} && env #{env_vars} ./node_modules/.bin/nuxt build')
        else
          execute :npm, "run build"
        end
      end
    end
  end


  desc "Generate static Nuxt 3 site (prerender → .output/public)"
  task :generate do
    on roles(fetch(:nuxt3_app_roles)) do
      within release_path do
        execute :echo, "'generating|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
        execute :echo, "'Deploy - Render - LOGS :: #{ Time.now.strftime("%d.%m.%Y - %H:%M") } ::' > #{shared_path}/#{fetch(:nuxt3_logs_file)}"
        if fetch(:nuxt3_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          execute %(bash -lc '#{nuxt3_nvm_prefix} && cd #{release_path} && env #{env_vars} ./node_modules/.bin/nuxt generate')
        else
          execute :npm, "run generate 2>&1 | tee -a #{shared_path}/#{fetch(:nuxt3_logs_file)}"
        end
      end
    end
  end


  desc "Sync full .output/ to shared (for SSR / Nitro service)"
  task :sync_output do
    on roles(fetch(:nuxt3_app_roles)) do
      execute :echo, "'syncing|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
      execute :rsync, "-a --delete #{release_path}/#{fetch(:nuxt3_build_dir)}/ #{shared_path}/#{fetch(:nuxt3_output_folder)}/"
      execute :echo, "'success|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_done_file)}"
    end
  end


  desc "Sync static .output/public/ to shared www (for nginx static serving)"
  task :sync_static do
    on roles(fetch(:nuxt3_app_roles)) do
      execute :echo, "'syncing|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
      execute :rsync, "-a --delete #{release_path}/#{fetch(:nuxt3_build_dir)}/public/ #{shared_path}/www/"
      execute :echo, "'success|deploy' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
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
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_stat_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_logs_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt3_done_file)}"
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

    %w[start stop restart enable disable is-enabled].each do |command|
      desc "#{command.capitalize} Nuxt 3 SSR service"
      task command.gsub(/-/, '_') do
        on roles fetch(:nuxt3_ssr_roles) do
          ensure_shared_pids_path if %w[start restart enable].include?(command)
          execute :sudo, :systemctl, command, fetch(:nuxt3_ssr_service_file)
        end
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
  after 'deploy:published', :rebuild_nuxt3_app do
    if fetch(:nuxt3_deploy_mode) == :static
      # Static: no node service, so the build+sync is the whole story.
      invoke "nuxt3:rebuild_static" if fetch(:nuxt3_static_hooks)
    else
      # SSR: always build+sync .output, but only auto-restart the Nitro
      # service when hooks are on. On the FIRST deploy the systemd unit does
      # not exist yet → a bare `ssr:restart` would fail. Set
      # `nuxt3_ssr_hooks=false` for the first deploy, then run
      # `cap <stage> nuxt3:ssr:configure` (uploads + enables + starts the unit
      # against the just-synced output), then flip `nuxt3_ssr_hooks=true` so
      # subsequent deploys restart cleanly. Same pattern as puma/sidekiq hooks.
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
end
