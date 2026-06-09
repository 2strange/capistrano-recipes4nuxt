namespace :load do
  task :defaults do
    set :certbot_roles,         -> { :web }
    set :certbot_path,          -> { "~" }
    set :certbot_domains,       -> { fetch(:nginx_major_domain,false) ? [fetch(:nginx_major_domain)] + Array(fetch(:nginx_domains)) : Array(fetch(:nginx_domains)) }
    set :certbot_www_domains,   -> { false }
    set :certbot_webroot,       -> { "#{shared_path}" }
    set :certbot_job_log,       -> { "#{shared_path}/log/lets_encrypt_cron.log" }
    set :certbot_job_type,      -> { 'systemd' }  # systemd / cron
    set :certbot_email,         -> { "" }
    # set :certbot_dh_path,       -> { fetch(:nginx_diffie_hellman_path, "/etc/ssl/certs/dhparam.pem")}
    # set :certbot_dh_size,       -> { 4096 }
  end
end

namespace :certbot do


  # Helper method to get the email address
  def fetch_certbot_email
    certbot_email = fetch(:certbot_email, "").strip
    if certbot_email.empty?
      puts "⚠️  No email address is set for Let's Encrypt!"
      puts "➡️  A valid email is required to receive expiration notifications."
      puts "➡️  Please enter a valid email address:"
      ask(:certbot_email, "Enter email for Let's Encrypt:")
      set(:certbot_email, fetch(:certbot_email)) # Store response
    end
    fetch(:certbot_email)
  end

  # Helper method to determine if `--expand` should be used
  def fetch_certbot_expand_option
    certbot_domains = Array(fetch(:certbot_domains))
    use_www_domains = fetch(:certbot_www_domains, false)
    
    should_expand = false
    if use_www_domains || certbot_domains.length > 1
      puts "🔍  It looks like you already have certificates or are adding new domains."
      puts "➡️  If you want to expand an existing certificate with new domains, select 'yes'."
      ask(:certbot_expand, "Use `--expand`? (yes/no):")
      should_expand = fetch(:certbot_expand).downcase.strip == "yes"
    end
    should_expand ? "--expand" : ""
  end

  # Helper method to generate domain arguments
  def fetch_certbot_domain_args
    certbot_domains = Array(fetch(:certbot_domains))
    use_www_domains = fetch(:certbot_www_domains, false)
    
    certbot_domains.map do |d|
      base_domain = d.gsub(/^\*?\./, "")
      domain_entry = "-d #{base_domain}"
      domain_entry += "-d www.#{base_domain}" if use_www_domains
      domain_entry
    end.join(" ")
  end


  ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## 
  
  desc "Install certbot LetsEncrypt"
  task :install do
    on roles fetch(:certbot_roles) do
      within fetch(:certbot_path) do
        execute :sudo, "apt update"
        execute :sudo, "apt install -y certbot"
      end
    end
  end
  
  
  desc "Generate LetsEncrypt certificate"
  task :generate do
    on roles fetch(:certbot_roles) do
      certbot_email = fetch_certbot_email
      expand_option = fetch_certbot_expand_option
      domain_args = fetch_certbot_domain_args
      
      execute :sudo, "certbot --non-interactive --agree-tos --allow-subset-of-names --email #{certbot_email} certonly --webroot -w #{fetch(:certbot_webroot)} #{domain_args} #{expand_option}"
    end
  end


  desc "Delete LetsEncrypt certificate"
  task :delete do
    on roles fetch(:certbot_roles) do
      # 1️⃣ Email check with explanation
      puts "⚠️  This will delete the certificates for the domain: #{Array(fetch(:certbot_domains))[0]}"
      ask(:certbot_delete_cert, "Are you sure? (yes|no):")
      if fetch(:certbot_delete_cert).to_s.downcase == "yes"
        # Execute Certbot delete
        puts "🔍  Deleting certificate... #{Array(fetch(:certbot_domains))[0]}"
        execute :sudo, "certbot --non-interactive delete --cert-name #{ Array(fetch(:certbot_domains))[0] }"
      else
        puts "🔍  Skipping certificate deletion..."
      end
    end
  end
  
  
  
  desc "Upload and setup LetsEncrypt Auto-renew-job"
  task :setup_auto_renew do
    on roles fetch(:certbot_roles) do
      if fetch(:certbot_job_type, 'systemd') == 'cron'
        # just once a week
        execute :sudo, "echo '0 0 * * 0 root certbot renew --no-self-upgrade --allow-subset-of-names --post-hook \"systemctl restart nginx\"  >> #{ fetch(:certbot_job_log) } 2>&1' | cat > #{ fetch(:certbot_path) }/lets_encrypt_cronjob"
        execute :sudo, "mv -f #{ fetch(:certbot_path) }/lets_encrypt_cronjob /etc/cron.d/lets_encrypt"
        execute :sudo, "chown -f root:root /etc/cron.d/lets_encrypt"
        execute :sudo, "chmod -f 0644 /etc/cron.d/lets_encrypt"
      else
        ## enable systemd timer (every 12 hours)
        execute :sudo, "systemctl enable certbot.timer"
        execute :sudo, "systemctl start certbot.timer"
        ## restart nginx if renewed
        execute :sudo, "mkdir -p /etc/systemd/system/certbot.service.d"
        execute :sudo, "echo -e '[Service]\nExecStartPost=/bin/systemctl restart nginx' | sudo tee /etc/systemd/system/certbot.service.d/override.conf"
        execute :sudo, "systemctl daemon-reload"
      end
    end
  end
  
  desc "Show logs for LetsEncrypt Auto-renew-job"
  task :auto_renew_logs do
    on roles fetch(:certbot_roles) do
      if fetch(:certbot_job_type, 'systemd') == 'cron'
        execute :sudo, "tail -n 50 #{fetch(:certbot_job_log)}"
      else
        execute :sudo, "journalctl -u certbot.timer --no-pager --since '7 days ago'"
        execute :sudo, "journalctl -u certbot.service --no-pager --since '7 days ago'"
      end
    end
  end
  
  desc "Remove LetsEncrypt Auto-renew-job"
  task :remove_auto_renew do
    on roles fetch(:certbot_roles) do
      if fetch(:certbot_job_type, 'systemd') == 'cron'
        execute :sudo, "rm -f /etc/cron.d/lets_encrypt"
      else
        execute :sudo, "systemctl stop certbot.timer"
        execute :sudo, "systemctl disable certbot.timer"
        execute :sudo, "rm -rf /etc/systemd/system/certbot.service.d"
        execute :sudo, "systemctl daemon-reload"
      end
    end
  end
  
  
  desc "Dry-Run Renew LetsEncrypt"
  task :dry_renew do
    on roles fetch(:certbot_roles) do
      # execute :sudo, "#{ fetch(:certbot_path) }/certbot-auto renew --dry-run"
      output = capture(:sudo, "certbot renew --dry-run")
      puts "#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#"
      output.each_line do |line|
          puts line
      end
      puts "#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#"
    end
  end


  desc "Renew LetsEncrypt certificates"
  task :renew do
    on roles fetch(:certbot_roles) do
      # execute :sudo, "#{ fetch(:certbot_path) }/certbot-auto renew --dry-run"
      output = capture(:sudo, "certbot renew")
      puts "#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#"
      output.each_line do |line|
          puts line
      end
      puts "#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#"
    end
  end
  

  # => ECDH (X25519) is automatically used → No need to generate DH params.
  ## desc "Generate Strong Diffie-Hellman Group"
  ## task :generate_dhparam do
  ##   on roles fetch(:certbot_roles) do
  ##     dh_path = fetch(:certbot_dh_path).to_s.split("/")
  ##     dh_path.pop
  ##     execute :sudo, "mkdir -p #{dh_path.join("/")}"
  ##     # Set key size (default to 4096 if not specified)
  ##     dh_key_size = fetch(:certbot_dh_size, 4096)
  ##     # Check if DH params already exist
  ##     if test("[ -f #{fetch(:certbot_dh_path)} ]")
  ##       puts "✅ DH parameters already exist at #{fetch(:certbot_dh_path)}, skipping generation."
  ##     else
  ##       puts "🔐 Generating #{dh_key_size}-bit Diffie-Hellman parameters..."
  ##       execute :sudo, "openssl dhparam -out #{fetch(:certbot_dh_path)} #{dh_key_size}"
  ##     end
  ##   end
  ## end


  desc "Check if TLS 1.3 is correctly enabled on the server"
  task :check_tls do
    on roles fetch(:certbot_roles) do
      domain = fetch(:nginx_major_domain, fetch(:nginx_domains).first)

      puts "🔍 Checking TLS 1.3 for #{domain}..."
      result = capture("curl -v --tlsv1.3 --tls-max 1.3 https://#{domain} 2>&1")

      if result.include?("SSL connection using TLSv1.3")
        puts "✅ TLS 1.3 is enabled and working for #{domain}!"
      else
        puts "❌ WARNING: TLS 1.3 may not be working! Check your Nginx SSL settings."
      end
    end
  end


  desc 'Get the DNS challenge txt-entry'
  task :dns_challenge_get do
    on roles fetch(:certbot_roles) do
      within release_path do

        certbot_email = fetch_certbot_email
        expand_option = fetch_certbot_expand_option
        domain_args = fetch_certbot_domain_args
        user = fetch(:user, "deploy") # Adjust to your user

        puts "cmd: sudo certbot certonly --manual --preferred-challenges=dns --agree-tos --dry-run --email #{certbot_email} #{domain_args} #{expand_option}"

        puts "🔄 Starting interactive Certbot session..."
        system("ssh -t #{user}@#{host.hostname} 'sudo certbot certonly --manual --preferred-challenges=dns --agree-tos --dry-run --email #{certbot_email} #{domain_args} #{expand_option}'")
      end
    end
  end

  desc 'Run Certbot to validate the DNS challenge'
  task :dns_challenge_validate do
    on roles fetch(:certbot_roles) do
      within release_path do
        certbot_email = fetch_certbot_email
        expand_option = fetch_certbot_expand_option
        domain_args = fetch_certbot_domain_args
        user = fetch(:user, "deploy") # Adjust to your user

        puts "cmd: sudo certbot certonly --manual --preferred-challenges=dns --agree-tos --email #{certbot_email} #{domain_args} #{expand_option}"

        puts "🔄 Starting interactive Certbot session..."
        system("ssh -t #{user}@#{host.hostname} 'sudo certbot certonly --manual --preferred-challenges=dns --agree-tos --email #{certbot_email} #{domain_args} #{expand_option}'")
      end
    end
  end

  
end



