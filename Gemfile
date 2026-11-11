# frozen_string_literal: true

source 'https://rubygems.org'

# Pull in all runtime + development dependencies declared in the gemspec
# (mixlib-config, chef_diff, rspec, rake, chef_zero).
gemspec

# chef_diff is not published to RubyGems — point Bundler straight at GitHub.
# `bundle install` fetches and caches it automatically; no manual clone needed.
gem 'chef_diff', git: 'https://github.com/One-com/chef_diff.git'

# Chef Infra gems come from Cinc, the community build of the Chef sources.
# Bundler takes a scoped gem's dependencies from the same source when it has
# them, so chef-config, chef-utils and inspec-core come from Cinc as well.
# The supported range lives in the gemspec. CHEF_VERSION (a major, e.g. `18`)
# narrows it to one major so CI can test each against the Ruby that Chef
# release embeds; left unset, Bundler picks whatever resolves.
chef_requirement = ENV['CHEF_VERSION']&.then { |major| "~> #{major}" }
source 'https://rubygems.cinc.sh' do
  gem 'chef', *chef_requirement
  gem 'knife', *chef_requirement
end

# Cinc hosts only unf_ext 0.0.7.2, but Chef 18 needs ~> 0.0.8.2 and Chef 19
# ~> 0.0.9.1. Because Cinc has the gem at all, Bundler takes it from there
# alone, which would silently hold every resolution at Chef 17. Naming it here
# moves it to rubygems.org. The cop reads every Gemfile `gem` as a
# development dependency; this one is a runtime dependency of chef.
# rubocop:disable-next Gemspec/DevelopmentDependencies
gem 'unf_ext'
