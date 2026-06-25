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

# Tests for lib/running_sushi/knife.rb
#
# Scope:
#   * Knife#initialize          - defaults + overrides
#   * Knife#cookbook_info       - pure parsing of cookbook directory names
#
# Anything that talks to a Chef Server (upload/delete/permissions/etc.) is
# deliberately excluded. Those methods are thin wrappers around Chef API
# objects, so testing them in-process would just become a test of Chef.

require_relative 'spec_helper'
require 'running_sushi/knife'

describe RunningSushi::Knife do
  # NOTE: RunningSushi::Knife exposes no readers for these fields, so the
  # initializer tests below intentionally use `instance_variable_get` to
  # inspect them. If readers are ever added, prefer those.
  describe '#initialize' do
    it 'applies sensible defaults when given no options' do
      knife = RunningSushi::Knife.new

      expect(knife.instance_variable_get(:@logger)).to be_nil
      expect(knife.instance_variable_get(:@user)).to eq('admin')
      expect(knife.instance_variable_get(:@host)).to eq('localhost')
      expect(knife.instance_variable_get(:@port)).to eq(443)
      expect(knife.instance_variable_get(:@pem)).to eq('/etc/chef-server/admin.pem')
    end

    it 'overrides defaults with provided options' do
      logger = Object.new
      opts = {
        logger: logger,
        user: 'sushi',
        host: 'chef.example.com',
        port: 8443,
        pem: '/tmp/sushi.pem',
        client_dir: '/repo/clients',
        cookbook_dirs: ['/repo/cookbooks'],
        databag_dir: '/repo/data_bags',
        environment_dir: '/repo/environments',
        node_dir: '/repo/nodes',
        role_dir: '/repo/roles',
        role_local_dir: '/repo/roles_local',
        checksum_dir: '/repo/checksums',
        master_path: '/var/chef/running_sushi_work',
        base_dir: '/var/chef/running_sushi_work/ops'
      }
      knife = RunningSushi::Knife.new(opts)

      opts.each do |key, value|
        expect(knife.instance_variable_get(:"@#{key}")).to eq(value)
      end
    end

    it 'leaves unrelated directory ivars nil when not provided' do
      knife = RunningSushi::Knife.new

      %i[client_dir cookbook_dirs databag_dir environment_dir node_dir
         role_dir role_local_dir checksum_dir master_path base_dir].each do |name|
        expect(knife.instance_variable_get(:"@#{name}")).to be_nil
      end
    end
  end

  describe '#cookbook_info' do
    let(:knife) { RunningSushi::Knife.new }

    it 'returns the cookbook name and nil version for an unversioned cookbook' do
      name, version = knife.cookbook_info(cookbook_change('webthing'))
      expect(name).to eq('webthing')
      expect(version).to be_nil
    end

    it 'preserves dashes within an unversioned cookbook name' do
      name, version = knife.cookbook_info(cookbook_change('my-cool-cookbook'))
      expect(name).to eq('my-cool-cookbook')
      expect(version).to be_nil
    end

    it 'splits "name-vX.Y.Z" into the cookbook name and the version string' do
      name, version = knife.cookbook_info(cookbook_change('morewebthing-v1.5.6'))
      expect(name).to eq('morewebthing')
      expect(version).to eq('1.5.6')
    end

    it 'handles dashed names with a trailing version tag' do
      name, version = knife.cookbook_info(cookbook_change('my-cool-cookbook-v2.0.0'))
      expect(name).to eq('my-cool-cookbook')
      expect(version).to eq('2.0.0')
    end

    it 'treats a missing v-prefix as part of the name' do
      name, version = knife.cookbook_info(cookbook_change('cookbook-1.2.3'))
      expect(name).to eq('cookbook-1.2.3')
      expect(version).to be_nil
    end

    it 'treats an incomplete semver tag as part of the name' do
      name, version = knife.cookbook_info(cookbook_change('cookbook-v1.2'))
      expect(name).to eq('cookbook-v1.2')
      expect(version).to be_nil
    end

    it 'only inspects the final dash-segment for the version tag' do
      # cookbook_info splits on "-" and only tries to match the regex on
      # the LAST segment, so a non-tag trailing segment (e.g. "rc1") means
      # the version is dropped and the whole string is treated as a name.
      name, version = knife.cookbook_info(cookbook_change('cookbook-v1.2.3-rc1'))
      expect(name).to eq('cookbook-v1.2.3-rc1')
      expect(version).to be_nil
    end
  end

  # ── Empty-list short-circuits ──────────────────────────────────────────────────
  #
  # Every upload/delete method gates its body with `if components.any?`.
  # Passing an empty list covers the false / no-op branch without touching
  # the Chef server.

  describe 'empty-list short-circuits' do
    let(:knife) { RunningSushi::Knife.new }

    it 'upload_standard is a no-op for an empty list' do
      expect { knife.upload_standard('roles', '/tmp', [], Chef::Role) }.not_to raise_error
    end

    it 'delete_standard is a no-op for an empty list' do
      expect { knife.delete_standard('roles', [], Chef::Role) }.not_to raise_error
    end

    it 'databag_upload is a no-op for an empty list' do
      expect { knife.databag_upload([]) }.not_to raise_error
    end

    it 'databag_delete is a no-op for an empty list' do
      expect { knife.databag_delete([]) }.not_to raise_error
    end

    it 'cookbook_upload is a no-op for an empty list' do
      expect { knife.cookbook_upload([]) }.not_to raise_error
    end

    it 'cookbook_delete is a no-op for an empty list' do
      expect { knife.cookbook_delete([]) }.not_to raise_error
    end

    it 'environment_upload is a no-op for an empty list' do
      expect { knife.environment_upload([]) }.not_to raise_error
    end

    it 'environment_delete is a no-op for an empty list' do
      expect { knife.environment_delete([]) }.not_to raise_error
    end

    it 'role_upload is a no-op for an empty list' do
      expect { knife.role_upload([]) }.not_to raise_error
    end

    it 'role_delete is a no-op for an empty list' do
      expect { knife.role_delete([]) }.not_to raise_error
    end

    it 'role_local_upload is a no-op for an empty list' do
      expect { knife.role_local_upload([]) }.not_to raise_error
    end

    it 'role_local_delete is a no-op for an empty list' do
      expect { knife.role_local_delete([]) }.not_to raise_error
    end

    it 'node_upload is a no-op for an empty list' do
      expect { knife.node_upload([], nil) }.not_to raise_error
    end

    it 'node_delete is a no-op for an empty list' do
      expect { knife.node_delete([]) }.not_to raise_error
    end

    it 'client_upload is a no-op for an empty list' do
      expect { knife.client_upload([]) }.not_to raise_error
    end

    it 'client_delete is a no-op for an empty list' do
      expect { knife.client_delete([]) }.not_to raise_error
    end
  end

  # ── #http_api ─────────────────────────────────────────────────────────────────

  describe '#http_api' do
    let(:knife) { RunningSushi::Knife.new }

    it 'returns a Chef::ServerAPI instance when Chef::ServerAPI is available' do
      api = double('api')
      allow(Chef::ServerAPI).to receive(:new).and_return(api)
      expect(knife.http_api).to be(api)
    end

    it 'falls back to Chef::REST when Chef::ServerAPI raises' do
      # Chef::REST was removed in newer Chef versions; stub the constant so the
      # rescue path in http_api can be exercised without a NameError.
      rest_class = stub_const('Chef::REST', Class.new)
      rest = double('rest')
      allow(Chef::ServerAPI).to receive(:new).and_raise(StandardError)
      allow(rest_class).to receive(:new).and_return(rest)
      expect(knife.http_api).to be(rest)
    end
  end

  # ── #verify_node_upload ───────────────────────────────────────────────────────

  describe '#verify_node_upload' do
    let(:logger) { double('logger', info: nil) }
    let(:knife)  { RunningSushi::Knife.new(logger: logger) }

    it 'returns true when the server checkpoint matches' do
      node = double('chef_node')
      allow(node).to receive(:normal).and_return(
        { 'running_sushi' => { 'checkpoint' => 'abc123' } }
      )
      allow(Chef::Node).to receive(:load).with('web01').and_return(node)
      expect(knife.verify_node_upload('web01', 'abc123')).to be true
    end

    it 'returns false when the server checkpoint does not match' do
      node = double('chef_node')
      allow(node).to receive(:normal).and_return(
        { 'running_sushi' => { 'checkpoint' => 'old_rev' } }
      )
      allow(Chef::Node).to receive(:load).with('web01').and_return(node)
      expect(knife.verify_node_upload('web01', 'abc123')).to be false
    end

    it 'returns false when Chef::Node.load raises' do
      allow(Chef::Node).to receive(:load).and_raise(StandardError, 'node not found')
      expect(knife.verify_node_upload('web01', 'abc123')).to be false
    end
  end

  # ── #create_databag_if_missing ────────────────────────────────────────────────

  describe '#create_databag_if_missing' do
    let(:logger) { double('logger', info: nil) }
    let(:knife)  { RunningSushi::Knife.new(logger: logger) }

    it 'does nothing when the databag already exists' do
      allow(Chef::DataBag).to receive(:load).with('mybag').and_return({ 'item' => {} })
      expect(Chef::DataBag).not_to receive(:new)
      knife.create_databag_if_missing('mybag')
    end

    it 'creates and saves the databag on a 404 response' do
      response = double('response', code: '404')
      allow(Chef::DataBag).to receive(:load).with('newbag')
                                            .and_raise(Net::HTTPClientException.new('404 Not Found', response))

      bag = double('bag')
      allow(Chef::DataBag).to receive(:new).and_return(bag)
      allow(bag).to receive(:name)
      allow(bag).to receive(:save)

      knife.create_databag_if_missing('newbag')

      expect(bag).to have_received(:name).with('newbag')
      expect(bag).to have_received(:save)
    end
  end

  # ── #delete_databag_if_empty ──────────────────────────────────────────────────

  describe '#delete_databag_if_empty' do
    let(:logger) { double('logger', info: nil) }
    let(:knife)  { RunningSushi::Knife.new(logger: logger) }

    it 'does nothing when the databag still has items' do
      allow(Chef::DataBag).to receive(:load).with('mybag').and_return({ 'item' => {} })
      expect(Chef::DataBag).not_to receive(:new)
      knife.delete_databag_if_empty('mybag')
    end

    it 'destroys the databag when it is empty' do
      allow(Chef::DataBag).to receive(:load).with('emptybag').and_return({})

      bag = double('bag')
      allow(Chef::DataBag).to receive(:new).and_return(bag)
      allow(bag).to receive(:name)
      allow(bag).to receive(:destroy)

      knife.delete_databag_if_empty('emptybag')

      expect(bag).to have_received(:name).with('emptybag')
      expect(bag).to have_received(:destroy)
    end

    it 'logs "not found" when the databag does not exist on the server' do
      response = double('response', code: '404')
      allow(Chef::DataBag).to receive(:load).with('missingbag')
                                            .and_raise(Net::HTTPClientException.new('404 Not Found', response))

      expect(logger).to receive(:info).with(/not found/)
      knife.delete_databag_if_empty('missingbag')
    end
  end
end
