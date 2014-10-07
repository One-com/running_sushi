# Encoding: utf-8
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
require 'chef/knife/cookbook_delete'
require 'chef/cookbook/cookbook_version_loader'
require 'chef/cookbook/metadata'
require 'chef/cookbook_uploader'

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
      @master_path = opts[:master_path]
      @base_dir = opts[:base_dir]
    end

    # TODO: set Chef::Log

    def environment_upload(environments)
      upload_standard('environments', @environment_dir, environments,
                      Chef::Environment)
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
            loader = Chef::Knife::Core::ObjectLoader.new(Chef::DataBagItem,
                                                         @logger)
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
      Chef::DataBag.load(databag)
    rescue Net::HTTPServerException => e
      raise e unless e.response.code == '404'
      @logger.info "=== Creating databag #{databag} ==="
      chef_databag = Chef::DataBag.new
      chef_databag.name(databag)
      chef_databag.save
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
              raise e unless e.response.code == '404'
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
        raise e unless e.response.code == '404'
        @logger.info "#{data_bag} not found. Cannot delete"
      end
    end

    def cookbook_upload(cookbooks)
      if cookbooks.any?
        @logger.info '=== Uploading cookbooks ==='
        cookbooks.each do |cb|
          @logger.info " Uploading #{cb}"

          # Load cookbook
          full_cb_path = File.join(@base_dir, cb.cookbook_dir, cb.name)
          cb_version_loader = \
            Chef::Cookbook::CookbookVersionLoader.new(full_cb_path)
          cb_version_loader.load_cookbooks

          # Handle versioned tagged cookbook by extracting name
          # from cookbook dir
          # Currently (Chef 11) Knife uses dir name as cookbook name
          cb_name, _ = cookbook_info(cb)
          cb_version_loader.instance_variable_set(:@cookbook_name, cb_name)
          cb_version = cb_version_loader.cookbook_version
          chef_cb_uploader = Chef::CookbookUploader.new(cb_version, {})
          chef_cb_uploader.upload_cookbooks

        end
      end
    end

    def cookbook_delete(cookbooks)
      if cookbooks.any?
        @logger.info '=== Deleting cookbooks ==='

        # Delete cookbooks using knife interface
        cookbooks.each do |cb|
          @logger.info " Deleting #{cb}"
          cb_name, cb_version = cookbook_info(cb)
          chef_cb_deleter = Chef::Knife::CookbookDelete.new
          Chef::Knife::CookbookDelete.load_deps
          chef_cb_deleter.config[:purge] = true
          chef_cb_deleter.cookbook_name = cb_name

          begin

            if cb_version
              @logger.info " Deleting #{cb_version}"
              chef_cb_deleter.delete_version_without_confirmation(cb_version)
            else
              @logger.info ' Deleting all'
              chef_cb_deleter.delete_all_without_confirmation
            end

          rescue Net::HTTPServerException => e
            raise e unless e.response.code == '404'
            @logger.info "#{cb_name} #{cb_version} not found. Cannot delete"
          end
        end

      end

    end

    def cookbook_info(cookbook)
      # Handle versioned tagged cookbook dirs
      # Format: "cookbook-name-vx.y.z"
      re = /^v((\d+)\.(\d+)\.(\d+))/
      name_parts = cookbook.name.split('-')
      m = name_parts[-1].match(re)
      if m
        name = name_parts[0..-2].join('-')
        version = m[1]
      else
        name = cookbook.name
        version = nil
      end

      return name, version
    end
  end
end
