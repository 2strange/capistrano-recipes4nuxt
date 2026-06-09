require 'capistrano/recipes4nuxt/base_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers

namespace :load do
  task :defaults do


    set :vue_use_nvm,               -> { false }
    set :vue_install_without_env,   -> { false }
    set :vue_nvm_path,              -> { "~/.nvm" }
    set :vue_nvm_version,           -> { "18.19.0" }
    set :vue_nvm_script,            -> { "$HOME/.nvm/nvm.sh" }

    set :vue_app_roles,             -> { :app }

    ## Maybe nonsense .. builds `APP_NAME_STG_DEPLOY_MODE`
    set :vue_stage_env_var,      -> { build_deploy_env_var }

    append :linked_dirs, 'node_modules'  # , '.nuxt', 'dist'

  end
end


namespace :vue do

  desc "output env var and stage"
  task :output_env do
    on roles(fetch(:vue_app_roles)) do
      puts "🔧 Vue.js stage: #{fetch(:stage)}"
      puts "🔧 Vue.js deploy mode: #{fetch(:vue_stage_env_var)}"
    end
  end

  desc "Install dependencies"
  task :install_dependencies do
    on roles(fetch(:vue_app_roles)) do
      within release_path do
        if fetch(:vue_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          nvm_prefix = "source #{fetch(:vue_nvm_script)} && nvm use #{fetch(:vue_nvm_version)}"
          if fetch(:vue_install_without_env, false)
            execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && npm install --production=false')
          else
            execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && env #{env_vars} npm install')
          end
        else
          execute :npm, "install"
        end
      end
    end
  end


  desc "Build Vue.js app"
  task :build do
    on roles(fetch(:vue_app_roles)) do
      within release_path do
        if fetch(:vue_use_nvm, false)
          env_vars = fetch(:default_env).map { |k, v| "#{k}=#{v}" }.join(" ")
          nvm_prefix = "source #{fetch(:vue_nvm_script)} && nvm use #{fetch(:vue_nvm_version)}"
          execute %(bash -lc '#{nvm_prefix} && cd #{release_path} && env #{env_vars} npm run build')
        else
          execute :npm, "run build"
        end
      end
    end
  end


  desc "Sync the dist folder to the shared folder"
  task :sync_dist do
    on roles(fetch(:vue_app_roles)) do
      execute :rsync, "-a --delete #{release_path}/dist/ #{shared_path}/www/"
    end
  end

  desc "Setup defaults for Vue.js app"
  task :setup_app do
    on roles(fetch(:vue_app_roles)) do
      ensure_shared_www_path
      ensure_shared_log_path
    end
  end

  desc "Fix permissions (just in case)"
  task :fix_permissions do
    on roles(fetch(:vue_app_roles)) do
      execute :sudo, :chown, "-R #{fetch(:user)}:#{fetch(:user)} #{release_path}"
    end
  end



  desc "Regenerate Vue.js app"
  task :rebuild_app do
    invoke "vue:install_dependencies"
    invoke "vue:build"
    invoke "vue:sync_dist"
  end


  desc "Install required node version with nvm"
  task :install_nvm_node do
    on roles(fetch(:vue_app_roles)) do
      if fetch(:vue_use_nvm, false)
        execute %(bash -lc 'source #{fetch(:vue_nvm_script)} && nvm install #{fetch(:vue_nvm_version)}')
      end
    end
  end

end

namespace :deploy do
  after 'deploy:published', :rebuild_nuxt_app do
    invoke "vue:rebuild_app"
  end
end


desc 'Server setup tasks'
task :setup do
  invoke 'vue:setup_app'
end

