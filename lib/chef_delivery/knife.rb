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

require 'json'
require 'fileutils'
require 'digest/md5'
require 'chef/node'
require 'chef/knife/core/object_loader'

module ChefDelivery
  # Knife does not have a usable API for using it as a lib
  # This could be possibly refactored to touch its internals
  # instead of shelling out
  class Knife

    def initialize(opts = {})
      @logger = opts[:logger] || nil
      @user = opts[:user] || 'admin'
      @home = opts[:home] || ENV['HOME'] #???
      @host = opts[:host] || 'localhost'
      @port = opts[:port] || 443
      @knife = opts[:bin] || 'knife' #???
      @pem = opts[:pem] || '/etc/chef-server/admin.pem'
      @repo_path = opts[:repo_path]
      @node_dir = opts[:node_dir]
      @role_dir = opts[:role_dir]
      @cookbook_dirs = opts[:cookbook_dirs]
      @databag_dir = opts[:databag_dir]
      @checksum_dir = opts[:checksum_dir]
      # TODO: Add environments, nodes and clients
    end

    # TODO: set Chef::Log

    def node_upload_all
      @logger.info "=== Uploading all nodes ==="
      nodes = Dir.glob(File.join(@repo_path, @node_dir, '*.json'))
      upload_standard('nodes', nodes, Chef::Node)
    end

    def node_upload(nodes)
      @logger.info "=== Uploading nodes ==="
      if nodes.any?
        nodes = nodes.map { |x| File.join(@node_dir, "#{x.name}.json") }
        upload_standard('nodes', nodes, Chef::Node)
      end
    end

    def upload_standard(component_type, files, klass)
      loader = Chef::Knife::Core::ObjectLoader.new(klass, @logger)
      files.each do |f|
        @logger.info "Upload from #{f}"
        updated = loader.load_from(component_type, f)
        updated.save
      end
    end

    def node_delete(nodes)
      @logger.info "=== Deleting nodes ==="
      if nodes.any?
        nodes.each do |node_name|
          @logger.info "Deleting node #{node_name}"
          node = Chef::Node.load(node_name)
          node.destroy
        end
      end
    end

    # def role_upload_all
    #   # TODO: use chef API
    #   roles = File.join(@role_dir, '*.rb')
    #   exec!("#{@knife} role from file #{roles} -c #{@config}", @logger)
    # end

    # def role_upload(roles)
    #   # TODO: use chef API
    #   if roles.any?
    #     roles = roles.map { |x| File.join(@role_dir, "#{x.name}.rb") }.join(' ')
    #     exec!("#{@knife} role from file #{roles} -c #{@config}", @logger)
    #   end
    # end

    # def role_delete(roles)
    #   # TODO: use knife API
    #   if roles.any?
    #     roles.each do |role|
    #       exec!(
    #         "#{@knife} role delete #{role.name} --yes -c #{@config}", @logger
    #       )
    #     end
    #   end
    # end

    # def cookbook_upload_all
    #   # TODO: use knife API
    #   exec!("#{@knife} cookbook upload -a -c #{@config}", @logger)
    # end

    # def cookbook_upload(cookbooks)
    #   # TODO: use knife API
    #   if cookbooks.any?
    #     cookbooks = cookbooks.map { |x| x.name }.join(' ')
    #     exec!("#{@knife} cookbook upload #{cookbooks} -c #{@config}", @logger)
    #   end
    # end

    # def cookbook_delete(cookbooks)
    #   # TODO: use knife API
    #   if cookbooks.any?
    #     cookbooks.each do |cookbook|
    #       exec!("#{@knife} cookbook delete #{cookbook.name}" +
    #               " --purge --yes -c #{@config}", @logger)
    #     end
    #   end
    # end

    # def databag_upload_all
    #   glob = File.join(@databag_dir, '*', '*.json')
    #   items = Dir.glob(glob).map do |file|
    #     BetweenMeals::Changes::Databag.new(
    #       { :status => :modified, :path => file }, @databag_dir
    #     )
    #   end
    #   databag_upload(items)
    # end

    # def databag_upload(databags)
    #   # TODO: use knife API
    #   if databags.any?
    #     databags.group_by { |x| x.name }.each do |dbname, dbs|
    #       create_databag_if_missing(dbname)
    #       dbitems = dbs.map do |x|
    #         File.join(@databag_dir, dbname, "#{x.item}.json")
    #       end.join(' ')
    #       exec!("#{@knife} data bag from file #{dbname} #{dbitems}", @logger)
    #     end
    #   end
    # end

    # def databag_delete(databags)
    #   # TODO: use knife API
    #   if databags.any?
    #     databags.group_by { |x| x.name }.each do |dbname, dbs|
    #       dbs.each do |db|
    #         exec!("#{@knife} data bag delete #{dbname} #{db.item}" +
    #                 " --yes -c #{@config}", @logger)
    #       end
    #       delete_databag_if_empty(dbname)
    #     end
    #   end
    # end

    # private

    # def create_databag_if_missing(databag)
    #   # TODO: use knife API
    #   s = Mixlib::ShellOut.new("#{@knife} data bag list" +
    #                            " --format json -c #{@config}").run_command
    #   s.error!
    #   db = JSON.load(s.stdout)
    #   unless db.include?(databag)
    #     exec!("#{@knife} data bag create #{databag} -c #{@config}", @logger)
    #   end
    # end

    # def delete_databag_if_empty(databag)
    #   # TODO: use knife API
    #   s = Mixlib::ShellOut.new("#{@knife} data bag show #{databag}" +
    #                            " --format json -c #{@config}").run_command
    #   s.error!
    #   db = JSON.load(s.stdout)
    #   if db.empty?
    #     exec!("#{@knife} data bag delete #{databag} --yes -c #{@config}",
    #           @logger)
    #   end
    # end
  end
end
