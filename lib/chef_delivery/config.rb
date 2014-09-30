# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

# Copyright 2013-present Facebook
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

require 'mixlib/config'
require 'logger'

module ChefDelivery
  # Config file parser and config object
  # Uses Mixlib::Config v1 syntax so it works in Chef10 omnibus...
  # it's compatible with v2, so it should work in 11 too.
  class Config
    extend Mixlib::Config

    dry_run false
    verbosity Logger::WARN
    timestamp false
    config_file '/etc/chef_delivery_config.rb'
    pidfile '/var/run/chef_delivery.pid'
    lockfile '/var/lock/subsys/chef_delivery'
    master_path '/var/chef/chef_delivery_work'
    repo_url nil
    reponame 'ops'
    pem '/etc/chef-server/admin.pem'
    chef_server_url 'http://127.0.0.1:8889'
    client_path 'clients'
    cookbook_paths ['cookbooks']
    databag_path 'databags'
    environment_path 'environments'
    node_path 'nodes'
    role_path 'roles'
    user_path 'users'
    rev_checkpoint 'chef_delivery_revision'
    knife_config '/root/.chef/knife.rb'
    knife_bin '/opt/chef/bin/knife'
    vcs_type 'git'
    vcs_path nil
    plugin_path '/etc/chef_delivery_plugin.rb'
  end
end
