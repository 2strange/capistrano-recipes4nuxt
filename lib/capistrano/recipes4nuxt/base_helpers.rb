require 'erb'
require 'stringio'

module Capistrano
  module Recipes4nuxt
    module BaseHelpers

      def build_deploy_env_var
        app_name = fetch(:application).gsub(/ /,'_').gsub(/-/,'_').upcase
        stage_name = fetch(:stage) == 'production' ? 'PROD' : 'STG'
        "#{ app_name }_#{ stage_name }_DEPLOY_MODE"
      end

      ## PAth helpers
      def ensure_shared_path(path)
        unless test("[ -d #{path} ]")
          puts "📂 Directory #{path} does not exist. Creating it..."
          execute :mkdir, "-p", path
        else
          puts "✅ Directory #{path} already exists."
        end
        ensure_shared_path_ownership
      end

      def ensure_shared_www_path
        ensure_shared_path("#{shared_path}/www")
      end

      def ensure_shared_log_path
        ensure_shared_path("#{shared_path}/log")
      end

      # Nuxt 3 SSR (Nitro) output dir – holds `server/index.mjs` + `public/`
      def ensure_shared_output_path
        ensure_shared_path("#{shared_path}/#{fetch(:nuxt3_output_folder, 'output')}")
      end

      # shared/config – holds the SSR runtime ENV file (nuxt3_ssr.env),
      # mirrors recipes2go ensure_shared_config_path (keys/puma).
      def ensure_shared_config_path
        ensure_shared_path("#{shared_path}/config")
      end

      # PID dir for the Nitro systemd service (mirrors recipes2go puma/sidekiq)
      def ensure_shared_pids_path
        ensure_shared_path("#{shared_path}/pids")
      end

      # bash -lc prefix that activates the requested node version via nvm.
      # Mirrors the nvm pattern used by the nuxt:/vue: build tasks.
      def nuxt3_nvm_prefix
        "source #{fetch(:nuxt3_nvm_script)} && nvm use #{fetch(:nuxt3_nvm_version)}"
      end

      # === Flag-file state helpers (G2, Contract §3.1) ===
      # The Admin/Backend UI reads `_builded_app` as one line `<state>|<actor>`,
      # mtime = last status change.
      #
      # DEPLOY-written states (actor = deploy — this gem writes them, below):
      #   installing → building → syncing → restarting → success
      #   plus ERROR-<task>|deploy on failure, so the UI can tell a hung deploy
      #   from a broken one.
      #
      # ADMIN-written state (actor = admin-interface — A2 / Content-Refresh, G14):
      #   purging|admin-interface  — written when the Admin "rebuild/refresh"
      #   button purges the Nitro route-rule caches. ⚠️ HONEST SCOPE: in A2 the
      #   purge is a BE→Nitro `curl` to an internal FE purge endpoint; the DEPLOY
      #   GEM never writes `purging|admin-interface`. It is produced by the
      #   BE worker / Admin path (Bill/Luke revier), NOT by `nuxt3.rake`. The gem
      #   only OWNS the read-contract (the file is a linked_file the gem seeds in
      #   :setup_app) and documents the slot — the actual write lives app-side.
      #   `generating|deploy` (npm re-render) does NOT occur in the SSR/A2 path
      #   (that was the rejected Variante-B behaviour). See Contract §3.2 / §6a.
      def nuxt3_remote_env_file
        "#{shared_path}/config/#{fetch(:nuxt3_ssr_env_file)}"
      end

      # Write a single flag-state line into _builded_app (actor defaults to deploy).
      def write_nuxt3_state(state, actor = "deploy")
        execute :echo, "'#{state}|#{actor}' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
      end

      # Run `block`, writing ERROR-<task>|<actor> into the flag file if it raises,
      # then re-raising so Capistrano aborts the deploy (no silent breakage).
      def with_nuxt3_error_state(task, actor = "deploy")
        yield
      rescue => e
        begin
          execute :echo, "'ERROR-#{task}|#{actor}' > #{shared_path}/#{fetch(:nuxt3_stat_file)}"
        rescue
          # never mask the original error behind a flag-write failure
        end
        raise e
      end

      # === Build-ENV sourcing (G3, Contract §4.3) ===
      # The build tasks source the SAME runtime ENV file the systemd service
      # uses, so prerendered pages and the live service can't drift. `set -a`
      # exports every KEY=value; the leading `[ -f … ]` guard keeps it
      # zero-config-safe when no ENV file has been uploaded yet.
      def nuxt3_build_env_source
        f = nuxt3_remote_env_file
        "set -a; [ -f #{f} ] && . #{f}; set +a"
      end

      # NUXT_APP_ENV=<stage> as a leading `env` assignment for non-nvm fallbacks
      # / inline use. The nvm branch sources the file + sets it via export.
      def nuxt3_app_env_assignment
        "NUXT_APP_ENV=#{fetch(:nuxt3_app_env)}"
      end

      # Disable + stop + remove an old systemd service file (no-op if absent).
      def remove_app_service(name = "SERVICE", service_path = "/lib/systemd/system", service_file = nil)
        if test("[ -f #{service_path}/#{service_file}.service ]")
          unless test("systemctl is-enabled #{service_file} || echo disabled") == "disabled"
            info "🔧 Disabling #{service_file} service..."
            execute :sudo, "systemctl disable #{service_file}"
          else
            info "✅ #{service_file} is already disabled, skipping."
          end
          puts "🔄 Stopping old #{name} service: #{service_file}.service"
          execute :sudo, "systemctl stop #{service_file}"
          puts "🗑 Removing old #{name} service file: #{service_file}.service"
          execute :sudo, :rm, "-f", "#{service_path}/#{service_file}.service"
        else
          puts "⚠️  Old #{name} service file #{service_file}.service does not exist, skipping removal."
        end
      end

      def ensure_shared_path_ownership
        # Fix ownership only if needed (avoids unnecessary chown operations)
        unless test("stat -c '%U:%G' #{shared_path} | grep #{fetch(:user)}:#{fetch(:user)}")
          puts "🔧 Fixing ownership of #{shared_path} and its parent directories..."
          execute :sudo, :chown, "-R #{fetch(:user)}:#{fetch(:user)} #{shared_path}"
          execute :sudo, :chown, "#{fetch(:user)}:#{fetch(:user)} #{fetch(:deploy_to)}"
        else
          puts "✅ Ownership is already correct."
        end
      end



      def template2go(from, to)
        erb = get_template_file(from)
        upload! StringIO.new( ERB.new(erb).result(binding) ), to
      end


      def render2go(tmpl)
        erb = get_template_file(tmpl)
        ERB.new(erb).result(binding)
      end


      def template_with_role(from, to, role = nil)
        erb = get_template_file(from)
        upload! StringIO.new(ERB.new(erb).result(binding)), to
      end


      def get_template_file( from )
        [
            File.join('config', 'deploy', 'templates', "#{from}.erb"),
            File.join('config', 'deploy', 'templates', "#{from}"),
            File.join('lib', 'capistrano', 'templates', "#{from}.erb"),
            File.join('lib', 'capistrano', 'templates', "#{from}"),
            File.expand_path("../../../generators/capistrano/recipes4nuxt/templates/#{from}.erb", __FILE__),
            File.expand_path("../../../generators/capistrano/recipes4nuxt/templates/#{from}", __FILE__)
        ].each do |path|
          return File.read(path) if File.file?(path)
        end
        # false
        raise "File '#{from}' was not found!!!"
      end


    end
  end
end




