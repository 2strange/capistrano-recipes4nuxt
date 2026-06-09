module Capistrano
  module Recipes4nuxt
    module NginxHelpers
      def joiner
        "\n                        "
      end

      def clear_domain(domain)
        "#{domain}".gsub(/^www\./, "").gsub(/^\*?\./, "")
      end

      def subdomain_regex(domain)
        "~^(www\.)?(?<sub>[\w-]+)#{Regexp.escape(".#{domain}")}"
      end

      def nginx_domains
        Array(fetch(:nginx_domains)).map { |d| clear_domain(d) }.uniq
      end

      def nginx_domains_with_www
        domains = []
        nginx_domains.each do |domain|
          domains << domain
          domains << "www.#{domain}" unless domain.match(/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
          domains << ".#{domain}" if fetch(:nginx_domain_wildcard, false)
        end
        domains
      end

      def nginx_major_domain
        fetch(:nginx_major_domain, false) ? clear_domain(fetch(:nginx_major_domain)) : false
      end

      def cert_domain
        fetch(:nginx_major_domain, false) ? fetch(:nginx_major_domain) : Array(fetch(:nginx_domains)).first
      end

      def nginx_all_domains_with_www
        domains = []
        nginx_domains.each do |domain|
          domains << domain
          domains << "www.#{domain}" unless domain.match(/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
          domains << ".#{domain}" if fetch(:nginx_domain_wildcard, false)
        end
        if nginx_major_domain
          domains << nginx_major_domain
          domains << "www.#{nginx_major_domain}" unless nginx_major_domain.match(/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
          domains << ".#{nginx_major_domain}" if fetch(:nginx_domain_wildcard, false)
        end
        domains
      end
    end
  end
end


