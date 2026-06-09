$:.push File.expand_path("../lib", __FILE__)

require_relative "lib/capistrano/recipes4nuxt/version"

Gem::Specification.new do |spec|
  spec.name        = "capistrano-recipes4nuxt"
  spec.version     = Capistrano::Recipes4nuxt::VERSION
  spec.authors     = ["Torsten Wetzel"]
  spec.email       = ["trendgegner@gmail.com"]
  spec.homepage    = "https://github.com/2strange/capistrano-recipes4nuxt"
  spec.summary     = "Capistrano recipes to deploy Nuxt 2 + 3 apps (proxy-ready). Successor of capistrano-nuxt2."
  spec.description = "Version-agnostic Capistrano recipes for deploying Nuxt 2 and Nuxt 3 apps (SSR + static). " \
                     "Includes nginx, certbot, proxy-nginx, nvm, and systemd service management. " \
                     "Successor of capistrano-nuxt2, compatible with the recipes2go setup."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/2strange/capistrano-recipes4nuxt"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{config,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  ## require capistrano
  spec.add_dependency       "capistrano",         ">= 3.15"

  ## require gems needed to deploy
  spec.add_dependency       "ed25519",            ">= 1.2", "< 2.0"
  spec.add_dependency       "bcrypt_pbkdf",       ">= 1.0", "< 2.0"

  # spec.add_dependency       "capistrano-npm",     ">= 1.0"
  # spec.add_dependency       "capistrano-rsync",   ">= 1.0"

end
