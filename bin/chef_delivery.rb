#!/opt/chef/embedded/bin/ruby
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

require 'chef_diff/util'
require 'chef_diff/repo/svn'
require 'chef_diff/repo/git'
require 'chef_diff/changeset'
require 'chef_delivery/config'
require 'chef_delivery/logging'
require 'chef_delivery/hooks'
require 'optparse'
require 'logger'

# rubocop:disable GlobalVars
$success = false
$status_msg = 'NO WORK DONE'
$lockfileh = nil

def action(msg)
  if ChefDelivery::Config.dry_run
    ChefDelivery::Log.warn("[DRYRUN] Would do: #{msg}")
  else
    ChefDelivery::Log.warn(msg)
  end
end

def get_lock
  ChefDelivery::Log.warn('Attempting to acquire lock')
  $lockfileh = File.open(ChefDelivery::Config.lockfile,
                         File::RDWR | File::CREAT, 0600)
  $lockfileh.flock(File::LOCK_EX)
  ChefDelivery::Log.warn('Lock acquired')
end

def write_pidfile
  File.write(ChefDelivery::Config.pidfile, Process.pid)
end

def checkpoint_path
  File.join(ChefDelivery::Config.master_path,
            ChefDelivery::Config.rev_checkpoint)
end

def write_checkpoint(rev)
  File.write(checkpoint_path, rev) unless ChefDelivery::Config.dry_run
end

def read_checkpoint
  ChefDelivery::Log.debug("Reading #{checkpoint_path}")
  File.exists?(checkpoint_path) ? File.read(checkpoint_path).strip : nil
end

def full_upload(knife)
  ChefDelivery::Log.warn('Uploading all cookbooks')
  knife.cookbook_upload_all
  ChefDelivery::Log.warn('Uploading all roles')
  knife.role_upload_all
  ChefDelivery::Log.warn('Uploading all databags')
  knife.databag_upload_all
end

def partial_upload(knife, repo, checkpoint, local_head)
  ChefDelivery::Log.warn(
    "Determing changes... from #{checkpoint} to #{local_head}"
  )

  begin
    changeset = ChefDiff::Changeset.new(
      ChefDelivery::Log,
      repo,
      checkpoint,
      local_head,
      {
        :cookbook_dirs =>
          ChefDelivery::Config.cookbook_paths,
        :client_dir =>
          ChefDelivery::Config.client_paths,
        :databag_dir =>
          ChefDelivery::Config.databag_path,
        :environment_dir =>
          ChefDelivery::Config.environment_path,
        :node_dir =>
          ChefDelivery::Config.node_path,
        :role_dir =>
          ChefDelivery::Config.role_path,
        :user_dir =>
          ChefDelivery::Config.user_path,
      },
    )
  rescue ChefDiff::Changeset::ReferenceError
    ChefDelivery::Log.error('Repo error, invalid revision, exiting')
    exit(2)
  end

  deleted_cookbooks = changeset.cookbooks.select { |x| x.status == :deleted }
  added_cookbooks = changeset.cookbooks.select { |x| x.status == :modified }
  deleted_roles = changeset.roles.select { |x| x.status == :deleted }
  added_roles = changeset.roles.select { |x| x.status == :modified }
  deleted_databags = changeset.databags.select { |x| x.status == :deleted }
  added_databags = changeset.databags.select { |x| x.status == :modified }

  {
    'Added cookbooks' => added_cookbooks,
    'Deleted cookbooks' => deleted_cookbooks,
    'Added roles' => added_roles,
    'Deleted roles' => deleted_roles,
    'Added databags' => added_databags,
    'Deleted databags' => deleted_databags,
  }.each do |msg, list|
    if list
      ChefDelivery::Log.warn("#{msg}: #{list}")
    end
  end

  knife.cookbook_delete(deleted_cookbooks) if deleted_cookbooks
  knife.cookbook_upload(added_cookbooks) if added_cookbooks
  knife.role_delete(deleted_roles) if deleted_roles
  knife.role_upload(added_roles) if added_roles
  knife.databag_delete(deleted_databags) if deleted_databags
  knife.databag_upload(added_databags) if added_databags
end

def upload_changed(repo, checkpoint)
  local_head = repo.head_rev
  base_dir = File.join(ChefDelivery::Config.master_path,
                       ChefDelivery::Config.reponame)

  knife = ChefDelivery::Knife.new(
    {
      :logger => ChefDelivery::Log,
      :config => ChefDelivery::Config.knife_config,
      :bin => ChefDelivery::Config.knife_bin,
      :client_dir => File.join(base_dir, ChefDelivery::Config.client_path),
      :cookbook_dirs => ChefDelivery::Config.cookbook_paths.map do |x|
        File.join(base_dir, x)
      end,
      :databag_dir => File.join(base_dir, ChefDelivery::Config.databag_path),
      :environment_dir => File.join(base_dir, ChefDelivery::Config.environment_path),
      :node_dir => File.join(base_dir, ChefDelivery::Config.node_path),
      :role_dir => File.join(base_dir, ChefDelivery::Config.role_path),
      :user_dir => File.join(base_dir, ChefDelivery::Config.user_path),
    }
  )

  if checkpoint
    partial_upload(knife, repo, checkpoint, local_head)
  else
    full_upload(knife)
  end
  return local_head
end

def setup_config
  options = {}
  OptionParser.new do |opts|
    options[:config_file] = ChefDelivery::Config.config_file
    opts.on('-n', '--dry-run', 'Dryrun mode') do |s|
      options[:dry_run] = s
    end
    opts.on('-v', '--verbosity', 'Verbosity level. Twice for debug.') do
      # If -vv is supplied this block is executed twice
      if options[:verbosity]
        options[:verbosity] = ::Logger::DEBUG
      else
        options[:verbosity] = ::Logger::INFO
      end
    end
    opts.on('-T', '--timestamp', 'Timestamp output') do |s|
      options[:timestamp] = s
    end
    opts.on('-c', '--config-file FILE', 'config file') do |s|
      unless File.exists?(File.expand_path(s))
        ChefDelivery::Log.error("Config file #{s} not found.")
        exit(2)
      end
      options[:config_file] = s
    end
    opts.on('-l', '--lockfile FILE', 'lockfile') do |s|
      options[:lockfile] = s
    end
    opts.on('-p', '--pidfile FILE', 'pidfile') do |s|
      options[:pidfile] = s
    end
  end.parse!
  if File.exists?(File.expand_path(options[:config_file]))
    ChefDelivery::Config.from_file(options[:config_file])
  end
  ChefDelivery::Config.merge!(options)
  ChefDelivery::Log.verbosity = ChefDelivery::Config.verbosity
  if ChefDelivery::Config.dry_run
    ChefDelivery::Log.warn('Dryrun mode activated, no changes will be made.')
  end
  ChefDelivery::Hooks.get(ChefDelivery::Config.plugin_path)
  at_exit do
    ChefDelivery::Hooks.atexit(ChefDelivery::Config.dry_run,
                                  $success, $status_msg)
  end
end

def get_repo
  repo_path = File.join(ChefDelivery::Config.master_path,
                        ChefDelivery::Config.reponame)
  r = ChefDiff::Repo.get(ChefDelivery::Config.vcs_type, repo_path,
                             ChefDelivery::Log)
  if ChefDelivery::Config.vcs_path
    r.bin = ChefDelivery::Config.vcs_path
  end
  r
end

setup_config

ChefDelivery::Hooks.preflight_checks(ChefDelivery::Config.dry_run)

get_lock
write_pidfile
repo = get_repo

ChefDelivery::Hooks.prerun(ChefDelivery::Config.dry_run)

if repo.exists?
  action('Updating repo')
  repo.update unless ChefDelivery::Config.dry_run
else
  unless ChefDelivery::Config.repo_url
    ChefDelivery::Log.error(
      'No repo URL was specified, and no repo is checked out'
    )
    exit(1)
  end
  action('Cloning repo')
  unless ChefDelivery::Config.dry_run
    repo.checkout(ChefDelivery::Config.repo_url)
  end
end

ChefDelivery::Hooks.post_repo_up(ChefDelivery::Config.dry_run)

if ChefDelivery::Config.dry_run && !repo.exists?
  ChefDelivery::Log.warn(
    'In dryrun mode, with no repo, there\'s not much I can dryrun'
  )
  ChefDelivery::Hooks.postrun(ChefDelivery::Config.dry_run, true,
                                 'dryrun mode')
  exit
end

checkpoint = read_checkpoint
if repo.exists? && repo.head_rev == checkpoint
  ChefDelivery::Log.warn('Repo has not changed, nothing to do...')
  $success = true
  $status_msg = "Success at #{checkpoint}"
else
  begin
    ver = upload_changed(repo, checkpoint)
    write_checkpoint(ver)
    $success = true
    $status_msg = "Success at #{ver}"
  rescue => e
    $status_msg = e.message
    e.backtrace.each do |line|
      ChefDelivery::Log.error(line)
    end
  end
end

ChefDelivery::Log.warn($status_msg)
ChefDelivery::Hooks.postrun(ChefDelivery::Config.dry_run, $success,
                               $status_msg)
# rubocop:enable GlobalVars
