# frozen_string_literal: true
#
# Runs the generated ENV loader (BaseHelpers#env_files_load_sh) in a real bash —
# embedded in `bash -lc '…'` exactly like the build tasks do — against tricky
# values that broke the old `set -a; . file` sourcing (v1.2.3, Mary-Fund).
#
# Run:  ruby test/env_loader_smoke_test.rb

require "tmpdir"
LIB = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(LIB) unless $LOAD_PATH.include?(LIB)
require "capistrano/recipes4nuxt/base_helpers"
include Capistrano::Recipes4nuxt::BaseHelpers

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  ok   #{desc}" : "  FAIL #{desc}")
  $failures += 1 unless ok
end

Dir.mktmpdir do |dir|
  a = File.join(dir, "next.env")
  b = File.join(dir, "database.env")
  File.write(a, <<~ENV)
    # comment
    MAIL_FROM=Mary <mary@example.com>
    QUOTED="hello world"
    SINGLE='it is $NOT expanded'
    export EXPORTED=yes
    WITH_EQ=a=b=c
    CRLF=windows\r
    DOLLAR=$HOME/literal
    BAD-KEY=ignored

    NEXT_PUBLIC_SITE_URL=https://mary.example.com
  ENV
  File.write(b, "DATABASE_URL=postgresql://u:p@127.0.0.1:5432/db\nQUOTED=override\n")
  missing = File.join(dir, "missing.env")

  snippet = env_files_load_sh([a, b, missing])
  check("snippet has no single quote (fits into bash -lc '…')") { !snippet.include?("'") }

  keys = %w[MAIL_FROM QUOTED SINGLE EXPORTED WITH_EQ CRLF DOLLAR NEXT_PUBLIC_SITE_URL DATABASE_URL]
  dump = keys.map { |k| %(printf "%s=[%s]\\n" #{k} "$#{k}") }.join(" && ")
  out = `bash -c '#{snippet} && #{dump} && echo CHAIN_OK' 2>&1`
  vals = out.lines.map(&:chomp).each_with_object({}) { |l, h| h[$1] = $2 if l =~ /\A(\w+)=\[(.*)\]\z/ }

  check("value with <> survives") { vals["MAIL_FROM"] == "Mary <mary@example.com>" }
  check("double quotes stripped") { vals["QUOTED"] == "override" } # later file wins
  check("single quotes stripped, no expansion") { vals["SINGLE"] == "it is $NOT expanded" }
  check("export prefix") { vals["EXPORTED"] == "yes" }
  check("= inside value kept") { vals["WITH_EQ"] == "a=b=c" }
  check("CRLF stripped") { vals["CRLF"] == "windows" }
  check("$ not expanded") { vals["DOLLAR"] == "$HOME/literal" }
  check("NEXT_PUBLIC_* loaded") { vals["NEXT_PUBLIC_SITE_URL"] == "https://mary.example.com" }
  check("second file loaded") { vals["DATABASE_URL"] == "postgresql://u:p@127.0.0.1:5432/db" }
  check("missing file + bad key don't break the && chain") { out.include?("CHAIN_OK") }
  check("vars are exported to child processes") do
    `bash -c '#{snippet} && bash -c "printf %s \\"\\$MAIL_FROM\\""'` == "Mary <mary@example.com>"
  end
end

puts
if $failures.zero?
  puts "ALL ENV-LOADER SMOKE CHECKS PASSED"
  exit 0
else
  puts "#{$failures} CHECK(S) FAILED"
  exit 1
end
