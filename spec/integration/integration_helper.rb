# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

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

# Shared setup for integration tests.
#
# Boots a single ChefZero in-process server for the entire test run so the
# cost of startup is paid once. Each test gets a clean slate via
# +CHEF_ZERO_SERVER.clear_data+ from a global RSpec +before(:each)+ hook,
# which makes tests independent without any per-describe cleanup boilerplate.

require_relative '../spec_helper'

require 'chef_zero/server'
require 'chef/config'
require 'chef/node'
require 'chef/role'
require 'chef/environment'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'chef/api_client_v1'
require 'chef/cookbook_version'
require 'running_sushi/knife'
require 'logger'
require 'tempfile'

FIXTURES_DIR = File.expand_path('../fixtures', __dir__)

# ── Chef Zero server (one per process) ───────────────────────────────────────

CHEF_ZERO_SERVER = ChefZero::Server.new(
  port: 18_900,
  generate_real_keys: false,
  log_level: :error
)
CHEF_ZERO_SERVER.start_background

CHEF_ZERO_KEY_FILE = Tempfile.new(['chef-zero', '.pem'])
CHEF_ZERO_KEY_FILE.write(ChefZero::PRIVATE_KEY)
CHEF_ZERO_KEY_FILE.flush

Chef::Config[:chef_server_url] = CHEF_ZERO_SERVER.url
Chef::Config[:node_name]       = 'admin'
Chef::Config[:client_key]      = CHEF_ZERO_KEY_FILE.path
Chef::Config[:ssl_verify_mode] = :verify_none

RSpec.configure do |config|
  # Wipe server state before every example so tests are fully independent
  # without requiring per-describe cleanup blocks.
  config.before(:each) { CHEF_ZERO_SERVER.clear_data if defined?(CHEF_ZERO_SERVER) }

  # Shut down the shared server and clean up the temp key file after the
  # full suite finishes.
  config.after(:suite) do
    CHEF_ZERO_SERVER.stop
    CHEF_ZERO_KEY_FILE.close!
  end
end

# ── Convenience helpers ───────────────────────────────────────────────────────

# Build a RunningSushi::Knife pointed at the standard fixture directories.
# Pass an explicit +logger:+ to capture log output in tests.
def build_knife(logger: Logger.new(File::NULL))
  RunningSushi::Knife.new({
                            logger: logger,
                            base_dir: FIXTURES_DIR,
                            node_dir: File.join(FIXTURES_DIR, 'nodes'),
                            role_dir: File.join(FIXTURES_DIR, 'roles'),
                            role_local_dir: File.join(FIXTURES_DIR, 'roles_local'),
                            environment_dir: File.join(FIXTURES_DIR, 'environments'),
                            databag_dir: File.join(FIXTURES_DIR, 'data_bags'),
                            client_dir: File.join(FIXTURES_DIR, 'clients')
                          })
end
