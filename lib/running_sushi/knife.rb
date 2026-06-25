# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

# Copyright 2013-2014 Facebook
# Copyright 2017-present One.com
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
require 'securerandom'
require 'chef/environment'
require 'chef/api_client_v1'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'chef/node'
require 'chef/role'
require 'chef/knife/core/object_loader'
require 'chef/knife/cookbook_delete'
require 'chef/cookbook/cookbook_version_loader'
require 'chef/cookbook_uploader'

module RunningSushi
  # Wraps Chef API operations (upload/delete for cookbooks, roles, nodes, etc.)
  # ClassLength: this class is a coherent Chef API surface — splitting it into
  # role/cookbook/node/etc. modules would add indirection without reducing code.
  # rubocop:disable Metrics/ClassLength
  class Knife
    # 15 fields, one assignment each — the explicit one-line-per-field form is
    # clearer than a dynamic loop and avoids hiding the default values.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      @role_local_dir = opts[:role_local_dir]
      @checksum_dir = opts[:checksum_dir]
      @master_path = opts[:master_path]
      @base_dir = opts[:base_dir]
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def http_api
      Chef::ServerAPI.new(Chef::Config[:chef_server_url])
    rescue StandardError
      Chef::REST.new(Chef::Config[:chef_server_url])
    end

    def environment_upload(environments)
      upload_standard('environments', @environment_dir, environments,
                      Chef::Environment)
    end

    def environment_delete(environments)
      delete_standard('environments', environments, Chef::Environment)
    end

    # Iterates over 4 ACL permissions with two independent rescue paths;
    # extracting further would add argument-passing without reducing branching.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def update_permissions(node)
      return unless Chef::Node.list.include?(node)

      @logger.info "Running ACL Update for node: #{node}"

      begin
        ace = http_api.get_rest("nodes/#{node}/_acl")
      rescue Net::HTTPClientException => e
        @logger.info 'ACL probably not supported, might be chef 11'
        return
      end

      %w[read update delete grant].each do |perm|
        # Continue if its included
        next if ace[perm]['actors'].include?(node)

        ace[perm]['actors'] << node
        begin
          http_api.put_rest("nodes/#{node}/_acl/#{perm}", perm => ace[perm])
        rescue Net::HTTPClientException => e
          @logger.warn "Failed to set permission : #{perm} on node #{node}"
        end
        @logger.info "Client \"#{node}\" granted \"#{perm}\" access on node \"#{node}\""
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Two-phase (destroy-then-create) with independent rescue blocks for each
    # phase; the second rescue is intentionally unreachable in practice but
    # guards against an unexpected 404 after a successful create.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def client_upload(clients)
      files = clients.map { |x| File.join(@client_dir, "#{x.full_name}.json") }
      files.each do |f|
        @logger.info "Upload from #{f}"
        r = JSON.parse(File.read(f))
        client_name = r['name']
        # Try updating client

        # Delete client if it does exists
        begin
          chef_client = Chef::ApiClientV1.new
          chef_client.name(r['name'])
          chef_client.destroy
        rescue Net::HTTPClientException => e
          raise e unless e.response.code == '404'

          @logger.info "#{client_name} did not exist, creating"
        end

        # Create client in all cases
        begin
          chef_client = Chef::ApiClientV1.new
          chef_client.name(r['name'])
          chef_client.public_key(r['public_key'])
          chef_client.admin(r['admin']) if r['admin']
          chef_client.create

          # Update permissions (Chef 12 thing)
          update_permissions(r['name'])
          @logger.info "Updated/Created #{client_name}"
        rescue Net::HTTPClientException => e
          raise e unless e.response.code == '404'

          @logger.warn "Should not be here! #{client_name}"
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    def client_delete(clients)
      delete_standard('clients', clients, Chef::ApiClientV1)
    end

    def node_upload(nodes, checkpoint)
      upload_standard('nodes', @node_dir, nodes, Chef::Node, checkpoint)
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

    def role_local_upload(roles_local)
      upload_standard('roles_local', @role_local_dir, roles_local, Chef::Role)
    end

    def role_local_delete(roles_local)
      delete_standard('roles_local', roles_local, Chef::Role)
    end

    def stamp_checkpoint(node_obj, checkpoint)
      node_obj.normal['running_sushi']['checkpoint'] = checkpoint
    end

    def upload_standard(component_type, path, components, klass, checkpoint = nil)
      return unless components.any?

      @logger.info "=== Uploading #{component_type} ==="
      loader = Chef::Knife::Core::ObjectLoader.new(klass, @logger)
      components.map { |x| File.join(path, "#{x.full_name}.json") }.each do |f|
        @logger.info "Upload from #{f}"
        updated = loader.object_from_file(f)
        stamp_checkpoint(updated, checkpoint) if checkpoint
        updated.save
        update_permissions(updated.name) if updated.is_a? Chef::Node
      end
    end

    def delete_standard(component_type, components, klass)
      return unless components.any?

      @logger.info "=== Deleting #{component_type} ==="
      components.each do |component|
        @logger.info "Deleting #{component.name}"
        klass.load(component.name).destroy
      rescue Net::HTTPClientException => e
        raise e unless e.response.code == '404'

        @logger.info "#{component_type} #{component.name} not found. Cannot delete"
      end
    end

    def upload_databag_item(dbname, entry)
      @logger.info "Upload #{dbname} #{entry.item}"
      db_item = File.join(@databag_dir, dbname, "#{entry.item}.json")
      loader = Chef::Knife::Core::ObjectLoader.new(Chef::DataBagItem, @logger)
      chef_db_item = Chef::DataBagItem.new
      chef_db_item.data_bag(dbname)
      chef_db_item.raw_data = loader.object_from_file(db_item)
      chef_db_item.save
    end

    def databag_upload(databags)
      return unless databags.any?

      @logger.info '=== Uploading databags ==='
      databags.group_by(&:name).each do |dbname, dbs|
        create_databag_if_missing(dbname)
        dbs.each { |entry| upload_databag_item(dbname, entry) }
      end
    end

    def create_databag_if_missing(databag)
      Chef::DataBag.load(databag)
    rescue Net::HTTPClientException => e
      raise e unless e.response.code == '404'

      @logger.info "=== Creating databag #{databag} ==="
      chef_databag = Chef::DataBag.new
      chef_databag.name(databag)
      chef_databag.save
    end

    def delete_databag_item(dbname, entry)
      @logger.info "Delete #{dbname} #{entry.item}"
      Chef::DataBagItem.load(dbname, entry.item).destroy(dbname, entry.item)
    rescue Net::HTTPClientException => e
      raise e unless e.response.code == '404'

      @logger.info "#{entry.item} not found. Cannot delete"
    end

    def databag_delete(databags)
      return unless databags.any?

      @logger.info '=== Deleting databag items ==='
      databags.group_by(&:name).each do |dbname, dbs|
        dbs.each { |entry| delete_databag_item(dbname, entry) }
        delete_databag_if_empty(dbname)
      end
    end

    def delete_databag_if_empty(databag)
      return if Chef::DataBag.load(databag).any?

      @logger.info "Deleting empty databag #{databag}"
      chef_databag = Chef::DataBag.new
      chef_databag.name(databag)
      chef_databag.destroy
    rescue Net::HTTPClientException => e
      raise e unless e.response.code == '404'

      @logger.info "#{databag} not found. Cannot delete"
    end

    def cookbook_upload(cookbooks)
      return unless cookbooks.any?

      @logger.info '=== Uploading cookbooks ==='
      cookbooks.each do |cb|
        @logger.info " Uploading #{cb}"
        # CookbookVersionLoader uses the dir name as cookbook name (Chef 11);
        # override it with the name extracted from the versioned-tag format.
        loader = Chef::Cookbook::CookbookVersionLoader.new(File.join(@base_dir, cb.cookbook_dir, cb.name))
        loader.load!
        cb_name, = cookbook_info(cb)
        loader.instance_variable_set(:@cookbook_name, cb_name)
        Chef::CookbookUploader.new(loader.cookbook_version, {}).upload_cookbooks
      end
    end

    def build_cookbook_deleter(cb_name)
      deleter = Chef::Knife::CookbookDelete.new
      Chef::Knife::CookbookDelete.load_deps
      deleter.config[:purge] = true
      deleter.cookbook_name = cb_name
      deleter
    end

    def run_cookbook_deletion(cb_name, cb_version, deleter)
      if cb_version
        @logger.info " Deleting #{cb_version}"
        deleter.delete_version_without_confirmation(cb_version)
      else
        @logger.info ' Deleting all'
        deleter.delete_all_without_confirmation
      end
    rescue Net::HTTPClientException => e
      raise e unless e.response.code == '404'

      @logger.info "#{cb_name} #{cb_version} not found. Cannot delete"
    end

    def cookbook_delete(cookbooks)
      return unless cookbooks.any?

      @logger.info '=== Deleting cookbooks ==='
      cookbooks.each do |cb|
        @logger.info " Deleting #{cb}"
        cb_name, cb_version = cookbook_info(cb)
        run_cookbook_deletion(cb_name, cb_version, build_cookbook_deleter(cb_name))
      end
    end

    def cookbook_info(cookbook)
      # Versioned dirs are formatted "cookbook-name-vX.Y.Z"; extract name + version.
      name_parts = cookbook.name.split('-')
      m = name_parts[-1].match(/^v((\d+)\.(\d+)\.(\d+))/)
      return [cookbook.name, nil] unless m

      [name_parts[0..-2].join('-'), m[1]]
    end

    def verify_node_upload(node, checkpoint)
      @logger.info "=== Verifying upload of #{node} ==="
      begin
        chef_node = Chef::Node.load(node)
        return true unless chef_node.normal['running_sushi']['checkpoint'] != checkpoint

        @logger.info " Upload verify of #{node} failed. Reuploading"
        false
      rescue StandardError
        @logger.info " Upload verify of #{node} failed. Reuploading"
        false
      end
    end
  end
  # rubocop:enable Metrics/ClassLength
end
