# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:test) do |t|
  t.pattern = 'spec/**/*_spec.rb'
end

task default: :test
