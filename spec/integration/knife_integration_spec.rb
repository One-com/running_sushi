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

# Integration tests for RunningSushi::Knife
#
# Each test exercises a real Chef API flow through an in-process ChefZero
# server started by integration_helper.rb. No stubs are used; the actual
# Chef client library sends HTTP requests and the server persists objects in
# memory for the duration of the test run.
#
# Isolation: integration_helper.rb installs a global RSpec before(:each)
# hook that calls +CHEF_ZERO_SERVER.clear_data+, so every test starts from a
# clean server state regardless of whether the previous test cleaned up after
# itself.
#
# Convention: every describe block exposes the knife under test via
# `let(:knife) { build_knife }` so individual tests just say `knife.xxx` and
# never re-instantiate per call site.

require_relative 'integration_helper'

# ── Roles ─────────────────────────────────────────────────────────────────────

describe 'role lifecycle' do
  let(:knife) { build_knife }

  it 'uploads a role from a JSON fixture' do
    knife.role_upload([make_change('test-role')])
    expect(Chef::Role.list).to include('test-role')
  end

  it 'deletes a role from the server' do
    knife.role_upload([make_change('test-role')])
    expect(Chef::Role.list).to include('test-role')
    knife.role_delete([make_change('test-role')])
    expect(Chef::Role.list).not_to include('test-role')
  end

  it 'silently ignores a delete for a role that does not exist' do
    log_io = StringIO.new
    build_knife(logger: Logger.new(log_io)).role_delete([make_change('nonexistent-role')])
    expect(log_io.string).to include('roles nonexistent-role not found. Cannot delete')
  end
end

# ── Local roles ───────────────────────────────────────────────────────────────
#
# role_local_upload / role_local_delete are thin wrappers around the standard
# upload/delete pipeline pointed at a different on-disk directory. Smoke tests
# here make sure the file resolution actually lands on roles_local/.

describe 'local role lifecycle' do
  let(:knife) { build_knife }

  it 'uploads a local role from the roles_local fixture directory' do
    knife.role_local_upload([make_change('local-role')])
    expect(Chef::Role.list).to include('local-role')
  end

  it 'deletes a local role from the server' do
    knife.role_local_upload([make_change('local-role')])
    expect(Chef::Role.list).to include('local-role')
    knife.role_local_delete([make_change('local-role')])
    expect(Chef::Role.list).not_to include('local-role')
  end

  it 'silently ignores a delete for a local role that does not exist' do
    log_io = StringIO.new
    build_knife(logger: Logger.new(log_io)).role_local_delete([make_change('nonexistent-local-role')])
    expect(log_io.string).to include('roles_local nonexistent-local-role not found. Cannot delete')
  end
end

# ── Environments ──────────────────────────────────────────────────────────────

describe 'environment lifecycle' do
  let(:knife) { build_knife }

  it 'uploads an environment from a JSON fixture' do
    knife.environment_upload([make_change('test-env')])
    expect(Chef::Environment.list).to include('test-env')
  end

  it 'deletes an environment from the server' do
    knife.environment_upload([make_change('test-env')])
    expect(Chef::Environment.list).to include('test-env')
    knife.environment_delete([make_change('test-env')])
    expect(Chef::Environment.list).not_to include('test-env')
  end

  it 'silently ignores a delete for an environment that does not exist' do
    log_io = StringIO.new
    build_knife(logger: Logger.new(log_io)).environment_delete([make_change('nonexistent-env')])
    expect(log_io.string).to include('environments nonexistent-env not found. Cannot delete')
  end
end

# ── Nodes ─────────────────────────────────────────────────────────────────────

describe 'node lifecycle' do
  let(:knife) { build_knife }

  it 'uploads a node from a JSON fixture' do
    knife.node_upload([make_change('web01')], 'sha_abc')
    expect(Chef::Node.list).to include('web01')
  end

  it 'writes the revision checkpoint into node.normal at upload time' do
    knife.node_upload([make_change('web01')], 'sha_abc')
    node = Chef::Node.load('web01')
    expect(node.normal['running_sushi']['checkpoint']).to eq('sha_abc')
  end

  it 'deletes a node from the server' do
    knife.node_upload([make_change('web01')], 'sha_abc')
    expect(Chef::Node.list).to include('web01')
    knife.node_delete([make_change('web01')])
    expect(Chef::Node.list).not_to include('web01')
  end

  it 'silently ignores a delete for a node that does not exist' do
    log_io = StringIO.new
    build_knife(logger: Logger.new(log_io)).node_delete([make_change('nonexistent-node')])
    expect(log_io.string).to include('nodes nonexistent-node not found. Cannot delete')
  end
end

# ── verify_node_upload ────────────────────────────────────────────────────────

describe 'verify_node_upload' do
  let(:knife) { build_knife }

  it 'returns true when the stored checkpoint matches' do
    knife.node_upload([make_change('web01')], 'sha_match')
    expect(knife.verify_node_upload('web01', 'sha_match')).to eq(true)
  end

  it 'returns false when the stored checkpoint differs' do
    knife.node_upload([make_change('web01')], 'sha_actual')
    expect(knife.verify_node_upload('web01', 'sha_stale')).to eq(false)
  end

  it 'returns false when the node does not exist on the server' do
    expect(knife.verify_node_upload('ghost-node', 'sha_any')).to eq(false)
  end
end

# ── Data bags ─────────────────────────────────────────────────────────────────

describe 'databag lifecycle' do
  let(:knife) { build_knife }

  it 'creates the bag if missing, then uploads the item' do
    knife.databag_upload([databag_change('my-bag', 'my-item')])
    expect(Chef::DataBag.load('my-bag')).to include('my-item')
  end

  it 'deletes the item and removes the bag when it becomes empty' do
    knife.databag_upload([databag_change('my-bag', 'my-item')])
    expect(Chef::DataBag.load('my-bag')).to include('my-item')
    knife.databag_delete([databag_change('my-bag', 'my-item')])
    expect { Chef::DataBag.load('my-bag') }.to raise_error(Net::HTTPClientException) do |err|
      expect(err.response.code).to eq('404')
    end
  end

  it 'silently ignores a delete for an item that does not exist' do
    log_io = StringIO.new
    build_knife(logger: Logger.new(log_io)).databag_delete([databag_change('my-bag', 'nonexistent-item')])
    expect(log_io.string).to include('nonexistent-item not found. Cannot delete')
  end

  it 'keeps the bag when other items remain after a partial delete' do
    # Upload two items so the bag still has content after the delete.
    knife.databag_upload([
                           databag_change('my-bag', 'my-item'),
                           databag_change('my-bag', 'my-other-item')
                         ])
    bag = Chef::DataBag.load('my-bag')
    expect(bag).to include('my-other-item')
    expect(bag).to include('my-item')
    knife.databag_delete([databag_change('my-bag', 'my-item')])

    # The bag must still exist and must still contain the surviving item.
    bag = Chef::DataBag.load('my-bag')
    expect(bag).to include('my-other-item')
    expect(bag).not_to include('my-item')
  end
end

# ── Clients ───────────────────────────────────────────────────────────────────

describe 'client lifecycle' do
  let(:knife) { build_knife }

  it 'creates a client from a JSON fixture' do
    knife.client_upload([make_change('test-client')])
    expect(Chef::ApiClientV1.list).to include('test-client')
  end

  it 'replaces the existing client on re-upload (attribute change visible)' do
    knife.client_upload([make_change('test-client')])
    # The first fixture is a plain (non-admin) client.
    expect(Chef::ApiClientV1.load('test-client').admin).to eq(false)

    # test-client-rotated.json keeps the same internal `name` but flips the
    # `admin` flag, so a working delete-then-create cycle must reflect that
    # on the server.
    knife.client_upload([make_change('test-client-rotated')])
    expect(Chef::ApiClientV1.load('test-client').admin).to eq(true)
  end

  it 'deletes a client from the server' do
    knife.client_upload([make_change('test-client')])
    expect(Chef::ApiClientV1.list).to include('test-client')
    knife.client_delete([make_change('test-client')])
    expect(Chef::ApiClientV1.list).not_to include('test-client')
  end
end

# ── Cookbooks ─────────────────────────────────────────────────────────────────

describe 'cookbook lifecycle (unversioned)' do
  let(:knife) { build_knife }

  it 'uploads a cookbook directory to the server' do
    knife.cookbook_upload([cookbook_change('test-cookbook')])
    expect(Chef::CookbookVersion.list).to include('test-cookbook')
  end

  it 'deletes all versions of a cookbook from the server' do
    knife.cookbook_upload([cookbook_change('test-cookbook')])
    expect(Chef::CookbookVersion.list).to include('test-cookbook')
    knife.cookbook_delete([cookbook_change('test-cookbook')])
    expect(Chef::CookbookVersion.list).not_to include('test-cookbook')
  end
end

describe 'cookbook lifecycle (versioned directory suffix)' do
  let(:knife) { build_knife }

  it 'strips the version tag from the directory name when uploading' do
    knife.cookbook_upload([cookbook_change('test-cookbook-v2.0.0')])
    expect(Chef::CookbookVersion.list).to include('test-cookbook')
  end

  it 'deletes only the tagged version, not all versions' do
    knife.cookbook_upload([cookbook_change('test-cookbook')])         # v1.0.0
    knife.cookbook_upload([cookbook_change('test-cookbook-v2.0.0')])  # v2.0.0
    expect { Chef::CookbookVersion.load('test-cookbook', '2.0.0') }.not_to raise_error
    knife.cookbook_delete([cookbook_change('test-cookbook-v2.0.0')])

    # The cookbook itself still exists (v1.0.0 was untouched)…
    expect(Chef::CookbookVersion.list).to include('test-cookbook')

    # …but specifically v2.0.0 is gone from the server.
    expect { Chef::CookbookVersion.load('test-cookbook', '2.0.0') }.to raise_error(Net::HTTPClientException) do |err|
      expect(err.response.code).to eq('404')
    end
  end
end
