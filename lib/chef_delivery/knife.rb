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
require 'chef/environment'
require 'chef/api_client'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'chef/node'
require 'chef/role'
require 'chef/user'
require 'chef/knife/core/object_loader'

module ChefDelivery
  # Knife does not have a usable API for using it as a lib
  # This could be possibly refactored to touch its internals
  # instead of shelling out
  class Knife

    def initialize(opts = {})
      @logger = opts[:logger] || nil
      @user = opts[:user] || 'admin'
      @host = opts[:host] || 'localhost'
      @port = opts[:port] || 443
      @pem = opts[:pem] || '/etc/chef-server/admin.pem'
      @client_dir = opts[:client_dir]
      @cookbook_dirs = opts[:cookbook_dirs]
      @databag_dir = opts[:databag_dir]
      @environment_dir = opts[:environment_dir]
      @node_dir = opts[:node_dir]
      @role_dir = opts[:role_dir]
      @checksum_dir = opts[:checksum_dir]
    end

    # TODO: set Chef::Log

    def environment_upload(environments)
      upload_standard('environments', @environment_dir, environments, Chef::Environment)
    end

    def environment_delete(environments)
      delete_standard('environments', environments, Chef::Environment)
    end

    def client_upload(clients)
      upload_standard('clients', @client_dir, clients, Chef::ApiClient)
    end

    def client_delete(clients)
      delete_standard('clients', clients, Chef::ApiClient)
    end

    def node_upload(nodes)
      upload_standard('nodes', @node_dir, nodes, Chef::Node)
    end

    def node_delete(nodes)
      delete_standard('nodes', nodes, Chef::Node)
    end

    def role_upload(roles)
      upload_standard('roles', @role_dir, roles, Chef::Role)
    end

    def role_delete(roles)
      delete_standard('roles', roles, Chef::Role)
    end

    def user_upload(users)
      upload_standard('users', @user_dir, users, Chef::User)
    end

    def user_delete(users)
      delete_standard('users', users, Chef::User)
    end

    def upload_standard(component_type, path, components, klass)
      if components.any?

        @logger.info "=== Uploading #{component_type} ==="
        loader = Chef::Knife::Core::ObjectLoader.new(klass, @logger)

        files = components.map { |x| File.join(path, "#{x.full_name}.json") }
        files.each do |f|
          @logger.info "Upload from #{f}"
          updated = loader.object_from_file(f)
          updated.save
        end
      end
    end

    def delete_standard(component_type, components, klass)
      if components.any?
        @logger.info "=== Deleting #{component_type} ==="
        components.each do |component|
          @logger.info "Deleting #{component.name}"
          chef_component = klass.load(component.name)
          chef_component.destroy
        end
      end
    end

    def databag_upload(databags)
      if databags.any?
        @logger.info '=== Uploading databags ==='
        databags.group_by { |x| x.name }.each do |dbname, dbs|
          create_databag_if_missing(dbname)
          dbs.map do |x|
            @logger.info "Upload #{dbname} #{x.item}"
            db_item = File.join(@databag_dir, dbname, "#{x.item}.json")
            loader = Chef::Knife::Core::ObjectLoader.new(Chef::DataBagItem, @logger)
            chef_db_item_json = loader.object_from_file(db_item)
            chef_db_item = Chef::DataBagItem.new
            chef_db_item.data_bag(dbname)
            chef_db_item.raw_data = chef_db_item_json
            chef_db_item.save
          end
        end
      end
    end

    def create_databag_if_missing(databag)
      begin
        chef_databag = Chef::DataBag.load(databag)
      rescue Net::HTTPServerException => e
        raise e unless e.response.code == "404"
        @logger.info "=== Creating databag #{databag} ==="
        chef_databag = Chef::DataBag.new
        chef_databag.name(databag)
        chef_databag.save
      end
    end

    def databag_delete(databags)
      if databags.any?
        @logger.info '=== Deleting databag items ==='
        databags.group_by { |x| x.name }.each do |dbname, dbs|
          dbs.map do |x|
            @logger.info "Delete #{dbname} #{x.item}"
            begin
              chef_db_item = Chef::DataBagItem.load(dbname, x.item)
              chef_db_item.destroy(dbname, x.item)
            rescue Net::HTTPServerException => e
              raise e unless e.response.code == "404"
              @logger.info "#{x.item} not found. Cannot delete"
            end
          end
          delete_databag_if_empty(dbname)
        end
      end
    end

    def delete_databag_if_empty(databag)
      @logger.info "Deleting empty databag #{databag}"
      chef_databag = Chef::DataBag.new
      chef_databag.name(databag)
      begin
        chef_databag.destroy
      rescue Net::HTTPServerException => e
        raise e unless e.response.code == "404"
        @logger.info "#{data_bag} not found. Cannot delete"
      end
    end

    def cookbook_upload(cookbooks)
    end

    def cookbook_delete(cookbooks)
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
