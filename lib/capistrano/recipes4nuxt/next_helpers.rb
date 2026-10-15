module Capistrano
  module Recipes4nuxt
    # Helpers for the Next.js recipe (`require "capistrano/recipes4nuxt/next"`).
    # Kept separate from BaseHelpers so the Nuxt paths stay untouched.
    module NextHelpers

      # shared/config/next.env — the per-instance runtime ENV (uploaded from
      # config/next_env/<stage>.env). Secrets live here or in :next_secrets_dir,
      # NEVER in the systemd unit (units under /lib/systemd/system are world-readable).
      def next_env_remote
        "#{shared_path}/config/#{fetch(:next_env_file)}"
      end

      # All ENV files the app sees, in load order (later wins):
      #   next.env → postgres URLs (if the postgres recipe is loaded) → extras.
      def next_all_env_files
        files = [next_env_remote]
        files << "#{shared_path}/#{fetch(:postgres_env_file)}" if fetch(:postgres_env_file, nil)
        Array(fetch(:next_extra_env_files, [])).each do |f|
          files << (f.start_with?("/") ? f : "#{shared_path}/#{f}")
        end
        files.uniq
      end

      # Reads the files like systemd (no shell evaluation); missing files are skipped.
      def next_env_source
        env_files_load_sh(next_all_env_files)
      end

      def next_nvm_prefix
        if fetch(:next_use_nvm, false)
          "source #{fetch(:next_nvm_script)} && nvm use #{fetch(:next_nvm_version)} >/dev/null"
        else
          "true"
        end
      end

      # Wrap a command in a login shell with nvm (+ optionally the runtime ENV).
      # NOTE: the command is embedded in single quotes — don't use ' inside it.
      def next_shell(cmd, dir: release_path, with_env: true)
        parts = [next_nvm_prefix]
        parts << next_env_source if with_env
        parts << "export NEXT_TELEMETRY_DISABLED=1"
        parts << "cd #{dir}"
        parts << cmd
        %(bash -lc '#{parts.join(" && ")}')
      end

      def next_secrets_path
        dir = fetch(:next_secrets_dir, nil)
        return nil if dir.nil? || dir.to_s.strip.empty?
        dir.start_with?("/") ? dir : "#{shared_path}/#{dir}"
      end

    end
  end
end
