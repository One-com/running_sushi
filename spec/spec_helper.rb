# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop:2:tabstop=2

# Copyright 2026-present One.com
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Shared test helpers for the Running Sushi test suite.
#
# Unit specs never reach a Chef Server, Syslog or the real repo: Chef API
# classes and Knife are replaced with verifying doubles, Log calls are
# stubbed or below the log level so Syslog is never opened, and
# checkpoints, lockfiles and repo checkouts live in a fresh tmpdir per
# example. The specs under integration/ instead talk to a real in-process
# ChefZero server (see integration/integration_helper.rb).

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

ROOT_DIR = File.expand_path('..', __dir__)
BIN_PATH = File.join(ROOT_DIR, 'bin', 'running-sushi')

# ── Fake change structs (mirror the ChefDiff::Changes shapes) ────────────────

# Mimics ChefDiff::Changes::Change — upload_standard uses full_name for the
# filename, delete_standard uses name for the server-side lookup.
Change = Struct.new(:full_name, :name)

# Mimics ChefDiff::Changes::Databag — needs name (bag) and item.
DatabagChange = Struct.new(:name, :item, :full_name)

# Mimics ChefDiff::Changes::Cookbook — needs name (dir) and cookbook_dir.
CookbookChange = Struct.new(:name, :cookbook_dir)

def make_change(name)
  Change.new(name, name)
end

def databag_change(bag, item)
  DatabagChange.new(bag, item, "#{bag}/#{item}")
end

def cookbook_change(dir_name, cookbook_dir = 'cookbooks')
  CookbookChange.new(dir_name, cookbook_dir)
end

# Changeset kind => [upload method, delete method] on RunningSushi::Knife:
# every Knife method that writes to the Chef Server. verify_node_upload and
# check_uploads only read, so they are deliberately absent. A new kind in
# chef_upload needs an entry here, or the chef_upload specs miss it. Local
# roles have no delete method: a role is deleted by name through role_delete,
# whichever tree its file was in.
KNIFE_WRITES = {
  cookbooks: %i[cookbook_upload cookbook_version_delete],
  roles: %i[role_upload role_delete],
  roles_local: %i[role_local_upload],
  databags: %i[databag_upload databag_delete],
  nodes: %i[node_upload node_delete],
  environments: %i[environment_upload environment_delete],
  clients: %i[client_upload client_delete]
}.freeze

# Matches the SystemExit that Kernel#exit(status) raises. A status check
# inside a raise_error block would count as a second expectation.
def exit_with(status)
  raise_error(an_instance_of(SystemExit).and(having_attributes(status: status)))
end

# The error Chef's REST client raises for an HTTP error status; Knife rescues
# it and branches on response.code ('404' means "not on the server").
def server_error(code)
  Net::HTTPClientException.new(code, instance_double(Net::HTTPResponse, code: code))
end

# Matches a list of changes by full_name, in any order.
def full_names(*names)
  match_array(names.map { |name| have_attributes(full_name: name) })
end

# Pull bin/running-sushi into the test process so its top-level helper methods
# are defined, WITHOUT running the real entry point. The no-op
# singleton `main` shadows the bottom-of-file `main` call at load time only;
# the real Object#main remains callable from examples (see spec for `main`).
define_singleton_method(:main) { nil } unless respond_to?(:main)
load BIN_PATH

RSpec.configure do |config|
  # RunningSushi::Config, Chef::Config and the Log level are process-wide
  # singletons that the code under test writes (setup_config sets all three).
  # Restoring them after every example keeps the outcome independent of run
  # order; without it a setup_config example that runs first points
  # Chef::Config away from the integration specs' ChefZero server.
  # Only the Log level is restored, not Log.reset!: that also forgets Syslog
  # is open, and the next unstubbed log call raises "syslog already open".
  config.around do |example|
    saved = [RunningSushi::Config.save, Chef::Config.save, RunningSushi::Log.level]
    example.run
  ensure
    RunningSushi::Config.restore(saved[0])
    Chef::Config.restore(saved[1])
    RunningSushi::Log.verbosity = saved[2]
  end
end
