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
  # rubocop:disable-next Metrics/ClassLength
  class Knife
    # The part of a ChefDiff change that the delete methods read
    # (#delete_standard): the name of the object to delete. Lets a caller
    # delete an object it knows only by name, with no file left in Git. For
    # a data bag item (#databag_delete) +name+ is its bag, +item+ its id.
    NameRef = Struct.new(:name, :item)

    # 15 fields, one assignment each — the explicit one-line-per-field form is
    # clearer than a dynamic loop and avoids hiding the default values.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
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
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def update_permissions(node)
      return unless Chef::Node.list.include?(node)

      @logger.info "Running ACL Update for node: #{node}"

      begin
        ace = http_api.get_rest("nodes/#{node}/_acl")
      rescue Net::HTTPClientException
        @logger.info 'ACL probably not supported, might be chef 11'
        return
      end

      %w[read update delete grant].each do |perm|
        # Continue if its included
        next if ace[perm]['actors'].include?(node)

        ace[perm]['actors'] << node
        begin
          http_api.put_rest("nodes/#{node}/_acl/#{perm}", perm => ace[perm])
        rescue Net::HTTPClientException
          @logger.warn "Failed to set permission : #{perm} on node #{node}"
        end
        @logger.info "Client \"#{node}\" granted \"#{perm}\" access on node \"#{node}\""
      end
    end

    # Two-phase (destroy-then-create) with independent rescue blocks for each
    # phase; the second rescue is intentionally unreachable in practice but
    # guards against an unexpected 404 after a successful create.
    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
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
        # destroy only needs the name; loading first would fetch a whole node.
        klass.new.tap { |object| object.name(component.name) }.destroy
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
      Chef::DataBagItem.new.destroy(dbname, entry.item)
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
        # The upload is named after the metadata (CookbookVersionLoader#cookbook_name),
        # not the dir; #check_uploads makes sure the two agree.
        loader = Chef::Cookbook::CookbookVersionLoader.new(File.join(@base_dir, cb.cookbook_dir, cb.name))
        loader.load!
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
      @logger.info " Deleting #{cb_version}"
      deleter.delete_version_without_confirmation(cb_version)
    rescue Net::HTTPClientException => e
      raise e unless e.response.code == '404'

      @logger.info "#{cb_name} #{cb_version} not found. Cannot delete"
    end

    # Deletes each [name, version] pair in +versions+; a version already gone
    # from the server is logged, not raised.
    def cookbook_version_delete(versions)
      return unless versions.any?

      @logger.info '=== Deleting cookbooks ==='
      versions.each do |name, version|
        @logger.info " Deleting #{name}"
        run_cookbook_deletion(name, version, build_cookbook_deleter(name))
      end
    end

    def cookbook_info(cookbook)
      # Versioned dirs are formatted "cookbook-name-vX.Y.Z"; extract name + version.
      name_parts = cookbook.name.split('-')
      m = name_parts[-1].match(/^v((\d+)\.(\d+)\.(\d+))/)
      return [cookbook.name, nil] unless m

      [name_parts[0..-2].join('-'), m[1]]
    end

    # Raised by #check_uploads; the message lists every offending file.
    class MismatchError < StandardError; end

    # Raises MismatchError when any file about to be uploaded contradicts its
    # path (see #name_mismatch, #cookbook_name_mismatch and
    # #version_mismatch); reads files only. Otherwise returns, per kind, the
    # id each change creates on the server (Upload#id), in the order of
    # +changes+.
    #
    # Both paths that write call this before their first write and before
    # the dry-run cut-off, so a mismatch fails either the same way:
    # chef_upload with the changes it applies, Reconcile.compare with every
    # file in Git. Checking inside the uploaders would be too late: they run
    # after the deletes, so a file renamed without fixing its name would see
    # its old object deleted and nothing uploaded in its place. Failing the
    # whole run keeps the server at the last good state and the checkpoint
    # where it was, so the run is retried once the file is fixed.
    #
    # +changes+ maps :cookbooks, :databags, :roles, :roles_local, :nodes,
    # :environments and :clients to their added changes; missing kinds are
    # fine.
    def check_uploads(changes)
      uploads = changes.to_h { |kind, list| [kind, list.map { |change| upload_identity(kind, change) }] }
      problems = uploads.values.flatten(1).filter_map(&:problem)
      raise MismatchError, problems.join("\n") unless problems.empty?

      uploads.transform_values { |list| list.map(&:id) }
    end

    # What uploading one file creates on the server, read from the file.
    # +id+ is the role/node/environment/client name, [bag, item id] for a
    # data bag item (an item id is only unique within its bag), or
    # [name, version] for a cookbook. +problem+ is why the file
    # contradicts its path (see #check_uploads), nil when it is consistent.
    Upload = Struct.new(:id, :problem, keyword_init: true)

    # Returns the Upload for one change of +kind+ (a #check_uploads key).
    #
    # The paths here and in #cookbook_identity must match the ones the
    # uploaders read (#upload_standard, #client_upload, #upload_databag_item,
    # #cookbook_upload); changing one requires changing the other.
    def upload_identity(kind, change)
      case kind
      when :cookbooks then cookbook_identity(change)
      when :databags
        upload = json_identity(File.join(@databag_dir, change.name, "#{change.item}.json"), 'id')
        Upload.new(id: [change.name, upload.id], problem: upload.problem)
      else
        json_identity(File.join(upload_dir(kind), "#{change.full_name}.json"), 'name')
      end
    end

    def json_identity(file, field)
      id = JSON.parse(File.read(file))[field]
      Upload.new(id: id, problem: name_mismatch(file, id, field: field))
    end

    # The id is what #cookbook_upload creates: the loader's cookbook_name and
    # the metadata version. cookbook_name falls back to the dir name when the
    # metadata has none, so the name check uses the metadata's own name
    # instead, making that fallback a mismatch (see #cookbook_name_mismatch).
    def cookbook_identity(change)
      path = File.join(@base_dir, change.cookbook_dir, change.name)
      loader = Chef::Cookbook::CookbookVersionLoader.new(path)
      loader.load!
      Upload.new(id: [loader.cookbook_name.to_s, loader.metadata.version],
                 problem: cookbook_problem(path, from_dir: cookbook_info(change), metadata: loader.metadata))
    end

    # The [name, version] each cookbook change would create (Upload#id).
    # Unlike #check_uploads this ignores mismatches with the path: the diff
    # path reads the dirs in Git of each deleted cookbook's name through it,
    # and a bad dir the diff did not touch is left to reconcile rather than
    # failing the run. An invalid metadata file still raises from the loader.
    def cookbook_ids(changes)
      changes.map { |change| cookbook_identity(change).id }
    end

    # Returns the #cookbook_name_mismatch and #version_mismatch messages for
    # the cookbook in +dir+, nil when it is consistent. +from_dir+ is
    # #cookbook_info's [name, tag], +metadata+ the cookbook's
    # Chef::Cookbook::Metadata.
    def cookbook_problem(dir, from_dir:, metadata:)
      name, tag = from_dir
      problems = [cookbook_name_mismatch(dir, name: name, metadata_name: metadata.name),
                  version_mismatch(dir, tag: tag, version: metadata.version)].compact
      problems.join("\n") unless problems.empty?
    end

    # Every cookbook version on the server, as [name, version] pairs.
    def server_cookbook_versions
      http_api.get('cookbooks?num_versions=all').flat_map do |name, info|
        info['versions'].map { |entry| [name, entry['version']] }
      end
    end

    def server_role_names
      Chef::Role.list.keys
    end

    def server_environment_names
      Chef::Environment.list.keys
    end

    def server_node_names
      Chef::Node.list.keys
    end

    def server_client_names
      Chef::ApiClientV1.list.keys
    end

    # Every data bag item on the server, as [bag, item id] pairs; one request
    # per bag.
    def server_databag_items
      Chef::DataBag.list.keys.flat_map { |bag| Chef::DataBag.load(bag).keys.map { |item| [bag, item] } }
    end

    def upload_dir(kind)
      { roles: @role_dir, roles_local: @role_local_dir, nodes: @node_dir,
        environments: @environment_dir, clients: @client_dir }.fetch(kind)
    end

    # Deletes look an object up by its filename (ChefDiff's Change#name, or
    # Change#item for data bag items), but uploads create it under the name
    # inside the file (+id+ for data bag items). An object uploaded from a
    # file whose two names differ could never be removed by deleting that
    # file.
    #
    # Returns an error message when +name+ differs from the basename of
    # +file+, nil when they match. +field+ is the JSON key +name+ was read
    # from, so the message points the operator at the right one.
    def name_mismatch(file, name, field: 'name')
      expected = File.basename(file, '.json')
      return nil if name == expected

      "#{file}: #{field} #{name.inspect} in the file does not match the filename"
    end

    # The cookbook counterpart of #name_mismatch: deletes take the version
    # from the directory tag (#cookbook_info), uploads from the metadata.
    #
    # Returns an error message when +tag+ is set and differs from +version+,
    # nil otherwise. Unversioned dirs have no tag and always pass.
    def version_mismatch(dir, tag:, version:)
      return nil if tag.nil? || tag == version

      "#{dir}: metadata version #{version} does not match the directory tag v#{tag}"
    end

    # Like #version_mismatch, but for the name: deletes take it from the dir
    # (#cookbook_info, minus any version tag), uploads from the metadata.
    #
    # +metadata_name+ is nil when the dir has no metadata file. Chef then
    # uploads it under the dir name at version 0.0.0, which for a stray dir in
    # a cookbook path (one holding only a README or CI config) is junk, so a
    # missing name is a mismatch too. A metadata file without a name never
    # gets here: CookbookVersionLoader#load! raises MetadataNotValid for it
    # first.
    #
    # Returns an error message when +metadata_name+ differs from +name+, nil
    # when they match.
    def cookbook_name_mismatch(dir, name:, metadata_name:)
      return nil if name == metadata_name

      "#{dir}: metadata name #{metadata_name.inspect} does not match the cookbook name #{name} from the directory"
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
end
