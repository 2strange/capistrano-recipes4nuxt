require 'capistrano/recipes4nuxt/base_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers

namespace :load do
  task :defaults do

    set :nuxt_stat_file,          -> { "_builded_app" }
    set :nuxt_logs_file,          -> { "_builded_logs" }
    set :nuxt_done_file,          -> { "_builded_frontend" }

    set :nuxt_use_nvm,            -> { false }
    set :nuxt_nvm_path,           -> { "~/.nvm" }
    set :nuxt_nvm_version,        -> { "18.19.0" }
    set :nuxt_nvm_script,         -> { "$HOME/.nvm/nvm.sh" }

    set :nuxt_app_roles,          -> { :app }

    ## Maybe nonsense .. builds `APP_NAME_STG_DEPLOY_MODE`
    set :nuxt_stage_env_var,      -> { build_deploy_env_var }


    append :linked_files, fetch(:nuxt_stat_file), fetch(:nuxt_logs_file), fetch(:nuxt_done_file)
    append :linked_dirs, 'node_modules'  # , '.nuxt', 'dist'

  end
end


namespace :nuxt do

  desc "output env var and stage"
  task :output_env do
    on roles(fetch(:nuxt_app_roles)) do
      puts "🔧 Nuxt.js stage: #{fetch(:stage)}"
      puts "🔧 Nuxt.js deploy mode: #{fetch(:nuxt_stage_env_var)}"
    end
  end

  desc "Install dependencies"
  task :install_dependencies do
    on roles(fetch(:nuxt_app_roles)) do
      within release_path do
        execute :echo, "'installing|deploy' > #{shared_path}/#{fetch(:nuxt_stat_file)}"
        execute :rm, "-rf node_modules/*"
        execute :rm, "-rf #{shared_path}/node_modules/*"
        if fetch(:nuxt_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          nvm_prefix = "source #{fetch(:nuxt_nvm_script)} && nvm use #{fetch(:nuxt_nvm_version)}"
          execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && env #{env_vars} npm install')
        else
          execute :npm, "install"
        end
      end
    end
  end


  desc "Build Nuxt.js app"
  task :build do
    on roles(fetch(:nuxt_app_roles)) do
      within release_path do
        execute :echo, "'building|deploy' > #{shared_path}/#{fetch(:nuxt_stat_file)}"
        if fetch(:nuxt_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          nvm_prefix = "source #{fetch(:nuxt_nvm_script)} && nvm use #{fetch(:nuxt_nvm_version)}"
          execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && env #{env_vars} ./node_modules/.bin/nuxt build')
        else
          execute :npm, "run build"
        end
      end
    end
  end


  desc "Export static files (if needed)"
  task :export do
    on roles(fetch(:nuxt_app_roles)) do
      within release_path do
        execute :echo, "'generating|deploy' > #{shared_path}/#{fetch(:nuxt_stat_file)}"
        execute :echo, "'Deploy - Render - LOGS :: #{ Time.now.strftime("%d.%m.%Y - %H:%M") } ::' > #{shared_path}/#{fetch(:nuxt_logs_file)}"
        if fetch(:nuxt_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          nvm_prefix = "source #{fetch(:nuxt_nvm_script)} && nvm use #{fetch(:nuxt_nvm_version)}"

          execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && env #{env_vars}  ./node_modules/.bin/nuxt generate')
        else
          execute :npm, "run generate 2>&1 | tee -a #{shared_path}/#{fetch(:nuxt_logs_file)}"
        end
      end
    end
  end

  desc "Sync the dist folder to the shared folder"
  task :sync_dist do
    on roles(fetch(:nuxt_app_roles)) do
      execute :echo, "'syncing|deploy' > #{shared_path}/#{fetch(:nuxt_stat_file)}"
      execute :rsync, "-a --delete #{release_path}/dist/ #{shared_path}/www/"
      execute :echo, "'success|deploy' > #{shared_path}/#{fetch(:nuxt_stat_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt_done_file)}"
    end
  end


  desc "Fix permissions (just in case)"
  task :fix_permissions do
    on roles(fetch(:nuxt_app_roles)) do
      execute :sudo, :chown, "-R #{fetch(:user)}:#{fetch(:user)} #{release_path}"
    end
  end


  desc "Setup defaults for Nuxt.js app"
  task :setup_app do
    on roles(fetch(:nuxt_app_roles)) do
      ensure_shared_www_path
      ensure_shared_log_path
      execute :touch, "#{shared_path}/#{fetch(:nuxt_stat_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt_logs_file)}"
      execute :touch, "#{shared_path}/#{fetch(:nuxt_done_file)}"
    end
  end


  desc "Regenerate Nuxt.js app"
  task :rebuild_app do
    invoke "nuxt:install_dependencies"
    invoke "nuxt:build"
    invoke "nuxt:export"
    invoke "nuxt:sync_dist"
  end

  desc "Regenerate Nuxt.js app"
  task :regenerate_app do
    invoke "nuxt:export"
    invoke "nuxt:sync_dist"
  end

  desc "Install required node version with nvm"
  task :install_nvm_node do
    on roles(fetch(:nuxt_app_roles)) do
      if fetch(:nuxt_use_nvm, false)
        execute %(bash -lc 'source #{fetch(:nuxt_nvm_script)} && nvm install #{fetch(:nuxt_nvm_version)}')
      end
    end
  end

end

namespace :deploy do
  after 'deploy:published', :rebuild_nuxt_app do
    invoke "nuxt:rebuild_app"
  end
end


desc 'Server setup tasks'
task :setup do
  invoke 'nuxt:setup_app'
end