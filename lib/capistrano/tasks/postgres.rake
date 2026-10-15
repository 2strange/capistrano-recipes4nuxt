require 'securerandom'
require 'stringio'
require 'capistrano/recipes4nuxt/base_helpers'
include Capistrano::Recipes4nuxt::BaseHelpers

# Database + login roles for a Node app on a local PostgreSQL (no database.yml —
# that's recipes2go/Rails). Installing PostgreSQL itself is server setup (T4).
#
#   Capfile:  require "capistrano/recipes4nuxt/postgres"
#
# Zero-config: one role named like the database, owning it, URL → DATABASE_URL.
# Multi-role (e.g. RLS setups):
#
#   set :postgres_db_roles, [
#     { name: "app_owner",   attributes: "BYPASSRLS",   env: "DATABASE_OWNER_URL", owner: true },
#     { name: "app_user",    attributes: "NOBYPASSRLS", env: "DATABASE_URL" },
#     { name: "app_service", attributes: "BYPASSRLS",   env: "DATABASE_SERVICE_URL" },
#   ]
#
# `postgres:setup` (also part of `cap <stage> setup`) is idempotent:
#   • creates missing roles (LOGIN + attributes) with a generated password,
#   • creates the database (owner, encoding, locale; template0),
#   • creates :postgres_extensions as superuser,
#   • writes the connection URLs into shared/config/database.env (0600) — the
#     passwords never leave the server and never appear on a command line,
#   • an existing role whose URL is already in database.env is left untouched;
#     an existing role WITHOUT a URL aborts (could be another app's role) —
#     take it over explicitly with `postgres:rotate_password[role]`.
# Assumes app + database on the same host (URLs point to :postgres_host).
# Grants / RLS / schema stay with the app's migrations.
# Role names are cluster-wide — on a shared cluster pick unique names.

namespace :load do
  task :defaults do
    set :postgres_roles,         -> { :db }
    set :postgres_database,      -> { "#{fetch(:application)}_#{fetch(:stage)}".gsub(/[^a-zA-Z0-9_]/, "_") }
    set :postgres_db_roles,      -> { [{ name: fetch(:postgres_database), env: "DATABASE_URL", owner: true }] }
    set :postgres_host,          -> { "127.0.0.1" }
    set :postgres_port,          -> { 5432 }
    set :postgres_encoding,      -> { "UTF8" }
    set :postgres_locale,        -> { "C.UTF-8" }
    set :postgres_extensions,    -> { [] }
    # REVOKE CREATE ON SCHEMA public FROM PUBLIC (default already on PG ≥ 15).
    set :postgres_revoke_public_create, -> { false }
    set :postgres_system_user,   -> { "postgres" }
    set :postgres_env_file,      -> { "config/database.env" }
  end
end

namespace :postgres do

  def pg_ident!(name)
    raise "❌ postgres: invalid identifier '#{name}' (use [a-z0-9_])" unless name.to_s =~ /\A[a-z_][a-z0-9_]*\z/
    name.to_s
  end

  def pg_roles_normalized
    roles = Array(fetch(:postgres_db_roles)).map { |r| r.transform_keys(&:to_sym) }
    owners = roles.select { |r| r[:owner] }
    raise "❌ postgres_db_roles: exactly one role needs owner: true" unless owners.size == 1
    roles.each do |r|
      pg_ident!(r[:name])
      raise "❌ postgres_db_roles: #{r[:name]} needs env:" unless r[:env].to_s =~ /\A[A-Z_][A-Z0-9_]*\z/
      raise "❌ postgres_db_roles: attributes for #{r[:name]} contain unexpected characters" unless r[:attributes].to_s =~ /\A[A-Z ]*\z/
    end
    roles
  end

  def pg_env_path
    "#{shared_path}/#{fetch(:postgres_env_file)}"
  end

  # Run SQL as the postgres superuser via stdin of an owner-only temp file —
  # keeps passwords out of `ps` and out of the SSHKit command log.
  def pg_run_sql(sql, db: "postgres")
    tmp = capture(:mktemp)
    execute :chmod, "600", tmp
    upload! StringIO.new(sql), tmp
    execute "sudo -u #{fetch(:postgres_system_user)} psql -v ON_ERROR_STOP=1 -q -d #{db} < #{tmp}; rc=$?; rm -f #{tmp}; exit $rc"
  end

  def pg_query(sql, db: "postgres")
    capture("sudo -u #{fetch(:postgres_system_user)} psql -tAq -d #{db} -c \"#{sql}\"").strip
  end

  def pg_read_env
    return {} unless test("[ -f #{pg_env_path} ]")
    capture(:cat, pg_env_path).lines.each_with_object({}) do |l, h|
      k, v = l.strip.split("=", 2)
      h[k] = v if k && v && !k.start_with?("#")
    end
  end

  def pg_write_env(env)
    content = "# managed by capistrano-recipes4nuxt postgres:setup — do not commit\n" +
              env.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
    execute :mkdir, "-p", File.dirname(pg_env_path)
    execute :touch, pg_env_path
    execute :chmod, "600", pg_env_path
    upload! StringIO.new(content), pg_env_path
    execute :chmod, "600", pg_env_path
  end

  def pg_url(role, password)
    "postgresql://#{role}:#{password}@#{fetch(:postgres_host)}:#{fetch(:postgres_port)}/#{fetch(:postgres_database)}"
  end

  def pg_set_password(role, attributes)
    password = SecureRandom.hex(24)
    exists = pg_query("select 1 from pg_roles where rolname='#{role}'") == "1"
    verb = exists ? "ALTER" : "CREATE"
    pg_run_sql(%(#{verb} ROLE "#{role}" LOGIN #{attributes} PASSWORD '#{password}';\n))
    info "🔑 #{verb == 'CREATE' ? 'created' : 'set password for'} role #{role}"
    password
  end

  desc "Create roles, database, extensions; write URLs to shared/config/database.env (idempotent)"
  task :setup do
    on roles(fetch(:postgres_roles)) do
      db = pg_ident!(fetch(:postgres_database))
      roles = pg_roles_normalized
      env = pg_read_env

      roles.each do |r|
        role = r[:name]
        exists = pg_query("select 1 from pg_roles where rolname='#{role}'") == "1"
        if exists && env[r[:env]].to_s.include?("://#{role}:")
          info "✅ role #{role} exists, #{r[:env]} present — unchanged"
          # keep attributes in sync without touching the password
          pg_run_sql(%(ALTER ROLE "#{role}" LOGIN #{r[:attributes]};\n)) unless r[:attributes].to_s.strip.empty?
          next
        end
        if exists
          # Role exists but we don't know its password. It may belong to ANOTHER
          # app on this cluster — never silently reset it.
          raise "❌ role #{role} already exists but #{r[:env]} is not in #{pg_env_path}. " \
                "If the role is really this app's, run `cap #{fetch(:stage)} postgres:rotate_password[#{role}]`."
        end
        env[r[:env]] = pg_url(role, pg_set_password(role, r[:attributes]))
      end

      owner = roles.find { |r| r[:owner] }[:name]
      if pg_query("select 1 from pg_database where datname='#{db}'") == "1"
        info "✅ database #{db} exists"
      else
        pg_run_sql(%(CREATE DATABASE "#{db}" OWNER "#{owner}" ENCODING '#{fetch(:postgres_encoding)}' LC_COLLATE '#{fetch(:postgres_locale)}' LC_CTYPE '#{fetch(:postgres_locale)}' TEMPLATE template0;\n))
        info "🗄  created database #{db} (owner #{owner})"
      end

      Array(fetch(:postgres_extensions)).each do |ext|
        pg_run_sql(%(CREATE EXTENSION IF NOT EXISTS "#{pg_ident!(ext)}";\n), db: db)
      end
      pg_run_sql("REVOKE CREATE ON SCHEMA public FROM PUBLIC;\n", db: db) if fetch(:postgres_revoke_public_create)

      pg_write_env(env)
      info "📝 URLs (#{roles.map { |r| r[:env] }.join(', ')}) → #{pg_env_path} (0600)"
    end
  end

  desc "Give one role a new password + update database.env: cap <stage> postgres:rotate_password[role]"
  task :rotate_password, :role do |_t, args|
    on roles(fetch(:postgres_roles)) do
      r = pg_roles_normalized.find { |x| x[:name] == args[:role] } or raise "❌ unknown role #{args[:role]}"
      env = pg_read_env
      env[r[:env]] = pg_url(r[:name], pg_set_password(r[:name], r[:attributes]))
      pg_write_env(env)
      info "↻ restart the app so it picks up the new #{r[:env]}"
    end
  end

  desc "Show roles + database state (no secrets)"
  task :status do
    on roles(fetch(:postgres_roles)) do
      names = pg_roles_normalized.map { |r| "'#{r[:name]}'" }.join(",")
      puts pg_query("select rolname, rolcanlogin, rolbypassrls from pg_roles where rolname in (#{names})")
      puts pg_query("select datname, pg_get_userbyid(datdba) from pg_database where datname='#{fetch(:postgres_database)}'")
      puts "env file: #{pg_env_path} (#{test("[ -f #{pg_env_path} ]") ? 'present' : 'missing'})"
    end
  end

end

desc 'Server setup tasks'
task :setup do
  invoke 'postgres:setup'
end
