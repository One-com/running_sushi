# frozen_string_literal: true

source 'https://rubygems.org'

# Pull in all runtime + development dependencies declared in the gemspec
# (mixlib-config, chef_diff, rspec, rake, chef_zero).
gemspec

# chef_diff is not published to RubyGems — point Bundler straight at GitHub.
# `bundle install` fetches and caches it automatically; no manual clone needed.
gem 'chef_diff', git: 'https://github.com/One-com/chef_diff.git'
