# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth:softtabstop:tabstop:2:2:2

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

require_relative 'spec_helper'

# ── chef_upload: Node re-upload and populated changeset scenarios ──────────────

describe 'chef_upload extra scenarios' do
  # A knife double that silently accepts every upload/delete call.
  let(:knife) do
    dbl = double('knife')
    %i[cookbook_delete cookbook_upload
       role_delete role_local_delete role_upload role_local_upload
       databag_delete databag_upload
       node_delete node_upload
       environment_delete environment_upload
       client_delete client_upload].each do |m|
      allow(dbl).to receive(m)
    end
    allow(dbl).to receive(:verify_node_upload).and_return(true)
    dbl
  end

  # Build a changeset double where every component list is empty.
  def empty_changeset
    cs = double('changeset')
    %i[cookbooks roles roles_local databags nodes environments clients].each do |m|
      allow(cs).to receive(m).and_return([])
    end
    cs
  end

  # Helper to create a change double with status and name.
  def change(status, name)
    double('change', status: status, full_name: name, name: name)
  end

  before do
    @orig_config = RunningSushi::Config.save
    @tmpdir = Dir.mktmpdir
    RunningSushi::Config.master_path      = @tmpdir
    RunningSushi::Config.reponame         = 'ops'
    RunningSushi::Config.dry_run          = false
    RunningSushi::Config.pod_name         = nil
    RunningSushi::Config.node_path        = 'nodes'
    RunningSushi::Config.client_path      = 'clients'
    RunningSushi::Config.environment_path = 'environments'
    RunningSushi::Config.role_local_path  = 'roles_local'
    RunningSushi::Config.role_path        = 'roles'

    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    # Stub the checkpoint I/O so tests don't depend on real files.
    allow(self).to receive(:read_node_checkpoint).and_return([nil, []])
    allow(self).to receive(:write_node_checkpoint)
    allow(ChefDiff::Changeset).to receive(:new).and_return(empty_changeset)
  end

  after do
    FileUtils.remove_entry(@tmpdir)
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  # ── Node re-upload scenarios ──────────────────────────────────────────────────

  describe 'node re-upload path' do
    it 're-queues a node whose server checkpoint failed verification' do
      allow(self).to receive(:read_node_checkpoint)
        .and_return(['rev123', ['web01']])
      allow(knife).to receive(:verify_node_upload).and_return(false)

      # Create the node file on disk.
      node_dir = File.join(@tmpdir, 'ops', 'nodes')
      FileUtils.mkdir_p(node_dir)
      File.write(File.join(node_dir, 'web01.json'), '{}')

      uploaded = nil
      allow(knife).to receive(:node_upload) { |nodes, _rev| uploaded = nodes }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      expect(uploaded.map(&:to_s)).to include('web01')
    end

    it 'does NOT re-queue a node whose repo file is gone' do
      allow(self).to receive(:read_node_checkpoint)
        .and_return(['rev123', ['web01']])
      allow(knife).to receive(:verify_node_upload).and_return(false)

      # Do NOT create the node file on disk (File.file? will be false).
      uploaded = nil
      allow(knife).to receive(:node_upload) { |nodes, _rev| uploaded = nodes }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      expect(uploaded).to eq([])
    end

    it 're-uploads multiple failed nodes when files exist' do
      allow(self).to receive(:read_node_checkpoint)
        .and_return(['rev123', %w[web01 web02 db01]])
      # Stub verify_node_upload to fail for each node.
      allow(knife).to receive(:verify_node_upload).and_return(false)

      # Create node files for web01 and db01, but not web02.
      node_dir = File.join(@tmpdir, 'ops', 'nodes')
      FileUtils.mkdir_p(node_dir)
      File.write(File.join(node_dir, 'web01.json'), '{}')
      File.write(File.join(node_dir, 'db01.json'), '{}')

      uploaded = nil
      allow(knife).to receive(:node_upload) { |nodes, _rev| uploaded = nodes }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      uploaded_names = uploaded.map(&:to_s)
      expect(uploaded_names).to include('web01')
      expect(uploaded_names).to include('db01')
      expect(uploaded_names).not_to include('web02')
    end

    it 'skips node re-upload when verify_node_upload returns true' do
      allow(self).to receive(:read_node_checkpoint)
        .and_return(['rev123', ['web01']])
      # Stub verify_node_upload to succeed.
      allow(knife).to receive(:verify_node_upload).and_return(true)

      # Create the node file.
      node_dir = File.join(@tmpdir, 'ops', 'nodes')
      FileUtils.mkdir_p(node_dir)
      File.write(File.join(node_dir, 'web01.json'), '{}')

      uploaded = nil
      allow(knife).to receive(:node_upload) { |nodes, _rev| uploaded = nodes }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      expect(uploaded).to eq([])
    end
  end

  # ── Populated changeset scenarios ──────────────────────────────────────────────

  describe 'populated changeset' do
    it 'executes select/reject! bodies for created/modified/deleted entries' do
      cs = empty_changeset
      allow(cs).to receive(:cookbooks).and_return([change(:created, 'cb1')])
      allow(cs).to receive(:databags).and_return([change(:modified, 'db1')])
      allow(cs).to receive(:nodes).and_return([change(:created, 'n1')])
      allow(cs).to receive(:environments).and_return([change(:created, 'e1')])
      allow(cs).to receive(:clients).and_return([change(:modified, 'c1')])
      allow(cs).to receive(:roles).and_return([change(:deleted, 'r1')])
      allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      # All methods should be called with their respective changes.
      expect(knife).to have_received(:cookbook_upload)
      expect(knife).to have_received(:role_delete)
      expect(knife).to have_received(:databag_upload)
      expect(knife).to have_received(:environment_upload)
      expect(knife).to have_received(:client_upload)
    end

    it 'partitions changes across all component types' do
      cs = empty_changeset
      allow(cs).to receive(:cookbooks)
        .and_return([change(:created, 'webapp'), change(:deleted, 'oldapp')])
      allow(cs).to receive(:databags)
        .and_return([change(:modified, 'secrets')])
      allow(cs).to receive(:nodes)
        .and_return([change(:created, 'web01'), change(:created, 'web02')])
      allow(cs).to receive(:environments)
        .and_return([change(:created, 'staging'), change(:deleted, 'dev')])
      allow(cs).to receive(:clients)
        .and_return([change(:modified, 'client1')])
      allow(cs).to receive(:roles)
        .and_return([change(:created, 'webserver')])
      allow(cs).to receive(:roles_local)
        .and_return([change(:deleted, 'local_role')])
      allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

      expect(knife).to receive(:cookbook_delete)
      expect(knife).to receive(:cookbook_upload)
      expect(knife).to receive(:role_delete)
      expect(knife).to receive(:role_local_delete)
      expect(knife).to receive(:role_upload)
      expect(knife).to receive(:databag_upload)
      expect(knife).to receive(:node_upload)
      expect(knife).to receive(:environment_delete)
      expect(knife).to receive(:environment_upload)
      expect(knife).to receive(:client_upload)

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')
    end

    it 'rejects global roles when local override file exists' do
      cs = empty_changeset
      allow(cs).to receive(:roles)
        .and_return([change(:created, 'myrole')])
      allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

      # Create the local-override file.
      local_dir = File.join(@tmpdir, 'ops', 'roles_local')
      FileUtils.mkdir_p(local_dir)
      File.write(File.join(local_dir, 'myrole.json'), '{}')

      expect(knife).to receive(:role_upload).with([])

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')
    end

    it 'promotes global role when local role is deleted' do
      cs = empty_changeset
      allow(cs).to receive(:roles_local)
        .and_return([change(:deleted, 'myrole')])
      allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

      # Create the global role file.
      global_dir = File.join(@tmpdir, 'ops', 'roles')
      FileUtils.mkdir_p(global_dir)
      File.write(File.join(global_dir, 'myrole.json'), '{}')

      uploaded_roles = nil
      allow(knife).to receive(:role_upload) { |roles| uploaded_roles = roles }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      expect(uploaded_roles.map(&:full_name)).to include('myrole')
    end

    it 'handles mixed modified and created cookbooks' do
      cs = empty_changeset
      allow(cs).to receive(:cookbooks)
        .and_return([
                      change(:created, 'newapp'),
                      change(:modified, 'oldapp')
                    ])
      allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

      uploaded = nil
      allow(knife).to receive(:cookbook_upload) { |cbs| uploaded = cbs }

      chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

      uploaded_names = uploaded.map(&:full_name)
      expect(uploaded_names).to include('newapp')
      expect(uploaded_names).to include('oldapp')
    end
  end
end
