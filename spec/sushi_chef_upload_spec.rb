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

# chef_upload sorts the changeset into a delete list and an upload list per
# kind, resolves each touched role, node, client and environment name to the
# file that defines it in Git and re-queues nodes whose last upload did not
# stick. The Knife and the Changesets are verifying doubles
# (sushi_role_precedence_spec.rb and sushi_named_objects_spec.rb let ChefDiff
# parse paths for real); the node checkpoint is a real file in a tmpdir.
describe 'chef_upload' do
  subject(:upload) { chef_upload(knife, :repo, 'old_rev', 'new_rev') }

  let(:tmpdir) { Dir.mktmpdir }
  # The server holds one version of the cookbook old-cookbooks, from an
  # unversioned dir, and no dir in Git provides it. Every cookbook change
  # names an unversioned dir (cookbook_info: [its name, no tag]).
  let(:knife) do
    instance_double(RunningSushi::Knife, verify_node_upload: true, check_uploads: nil, cookbook_ids: [],
                                         server_cookbook_versions: [%w[old-cookbooks 1.0.0]],
                                         **KNIFE_WRITES.values.flatten.to_h { |m| [m, nil] })
  end
  # Kind => changes; kinds left out are empty.
  let(:changes) { {} }
  # Kind => every cookbook dir and every file of the kinds decided by name
  # in Git, as chef_upload lists them with a nil start rev; by default the
  # changes not deleted.
  let(:in_git) do
    %i[cookbooks roles roles_local nodes environments clients].to_h do |kind|
      [kind, changes.fetch(kind, []).reject { |c| c.status == :deleted }]
    end
  end

  def change(status, name)
    ChefDiff::Changes::Change.new.tap do |c|
      c.status = status
      c.name = name
    end
  end

  before do
    RunningSushi::Config.master_path = tmpdir
    changeset = instance_double(ChefDiff::Changeset, **KNIFE_WRITES.keys.to_h { |k| [k, changes.fetch(k, [])] })
    tree = instance_double(ChefDiff::Changeset, **in_git)
    allow(ChefDiff::Changeset).to receive(:new) { |_log, _repo, start_ref| start_ref ? changeset : tree }
    allow(knife).to receive(:cookbook_info) { |cookbook| [cookbook.name, nil] }
    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
  end

  after { FileUtils.remove_entry(tmpdir) }

  # The Config default dirs, relative to the checkout.
  def repo_dirs
    { cookbook_dirs: ['cookbooks'], client_dir: 'clients', databag_dir: 'data_bags', environment_dir: 'environments',
      node_dir: 'nodes', role_local_dir: 'roles_local', role_dir: 'roles' }
  end

  it 'diffs the checkpoint against the head' do
    upload
    expect(ChefDiff::Changeset).to have_received(:new).with(RunningSushi::Log, :repo, 'old_rev', 'new_rev', repo_dirs)
  end

  context 'when nothing changed' do
    KNIFE_WRITES.values.flatten.each do |m|
      it "passes an empty list to #{m}" do
        upload
        expect(knife).to have_received(m).with([], any_args)
      end
    end

    # Listing them loads the metadata of every cookbook dir in Git.
    it 'reads no cookbook ids' do
      upload
      expect(knife).not_to have_received(:cookbook_ids)
    end

    it 'reads no cookbook versions from the server' do
      upload
      expect(knife).not_to have_received(:server_cookbook_versions)
    end
  end

  context 'with created, modified and deleted entries' do
    # Local roles only count with a pod_name (see local_roles?).
    before { RunningSushi::Config.pod_name = 'pod1' }

    let(:changes) do
      KNIFE_WRITES.keys.to_h do |kind|
        [kind, [change(:modified, "new-#{kind}"), change(:modified, "mod-#{kind}"), change(:deleted, "old-#{kind}")]]
      end
    end

    KNIFE_WRITES.each do |kind, (upload_method, delete_method)|
      it "uploads created and modified #{kind}" do
        upload
        expect(knife).to have_received(upload_method).with(full_names("new-#{kind}", "mod-#{kind}"), any_args)
      end

      next if kind.start_with?('roles') || kind == :cookbooks

      it "deletes deleted #{kind}" do
        upload
        expect(knife).to have_received(delete_method).with([have_attributes(name: "old-#{kind}")])
      end
    end

    it 'deletes the server versions of deleted cookbooks' do
      upload
      expect(knife).to have_received(:cookbook_version_delete).with([%w[old-cookbooks 1.0.0]])
    end

    # A dir of the same name in another cookbook path.
    context 'when a dir in Git provides the version' do
      let(:in_git) { super().merge(cookbooks: [change(:modified, 'old-cookbooks')]) }

      before { allow(knife).to receive(:cookbook_ids).and_return([%w[old-cookbooks 1.0.0]]) }

      it 'deletes no cookbook version' do
        upload
        expect(knife).to have_received(:cookbook_version_delete).with([])
      end

      it 'reads the cookbook ids of that dir' do
        upload
        expect(knife).to have_received(:cookbook_ids).with(full_names('old-cookbooks'))
      end
    end

    # new-cookbooks and mod-cookbooks are in Git, but can't provide
    # old-cookbooks; an untouched cookbook Chef can't load must not fail the
    # delete.
    it "loads no other cookbook's metadata" do
      upload
      expect(knife).to have_received(:cookbook_ids).with([])
    end

    it 'deletes deleted roles, global and local, by name' do
      upload
      expect(knife).to have_received(:role_delete)
        .with(contain_exactly(have_attributes(name: 'old-roles'), have_attributes(name: 'old-roles_local')))
    end

    # Regression: `-n` used to stop only the repo update and the checkpoint
    # writes, while chef_upload went on to call every Knife upload/delete for
    # real. Unlike the dry-run cases in spec/sushi_main_spec.rb, this runs
    # chef_upload itself.
    context 'when in dry-run mode' do
      before { RunningSushi::Config.dry_run = true }

      it 'makes no writes to the Chef Server', :aggregate_failures do
        upload
        KNIFE_WRITES.values.flatten.each { |m| expect(knife).not_to have_received(m) }
      end

      it 'still checks the files of every kind' do
        upload
        expect(knife).to have_received(:check_uploads).with(hash_including(*KNIFE_WRITES.keys))
      end

      it 'logs what it would apply' do
        upload
        expect(RunningSushi::Log).to have_received(:warn).with('[DRYRUN] Would do: Applying changes to the Chef Server')
      end

      it 'writes no node checkpoint' do
        upload
        expect(File).not_to exist(node_checkpoint_path)
      end
    end

    context 'when a file to upload contradicts its path' do
      before { allow(knife).to receive(:check_uploads).and_raise(RunningSushi::Knife::MismatchError) }

      it 'fails before any write, deletes included', :aggregate_failures do
        expect { upload }.to raise_error(RunningSushi::Knife::MismatchError)
        KNIFE_WRITES.values.flatten.each { |m| expect(knife).not_to have_received(m) }
      end
    end
  end

  # The role is both the winner to upload and a changed global role, two
  # Change objects for one file.
  context 'when a global role without a local override changed' do
    let(:changes) { { roles: [change(:modified, 'web')] } }

    it 'checks it once' do
      upload
      expect(knife).to have_received(:check_uploads).with(hash_including(roles: full_names('web')))
    end
  end

  # Which file wins is specced in sushi_role_precedence_spec.rb. A mismatch in
  # the losing global role must still fail here, as it does on servers without
  # the local role and in reconcile.
  context 'when a global role has a local override' do
    let(:changes) { { roles: [change(:modified, 'web')] } }
    let(:in_git) { { roles: [change(:modified, 'web')], roles_local: [change(:modified, 'web')] } }

    before { RunningSushi::Config.pod_name = 'pod1' }

    it 'still checks the global role' do
      upload
      expect(knife).to have_received(:check_uploads).with(hash_including(roles: full_names('web')))
    end
  end

  context 'with nodes from an unverified upload' do
    # web01 failed verification, web02 failed but left the repo, db01 passed.
    let(:in_git) { { nodes: [change(:modified, 'web01'), change(:modified, 'db01')] } }

    before do
      write_node_checkpoint(%w[web01 web02 db01], 'rev123')
      allow(knife).to receive(:verify_node_upload) { |node, _rev| node == 'db01' }
    end

    it 'verifies them at the stored rev' do
      upload
      expect(knife).to have_received(:verify_node_upload).with('web01', 'rev123')
    end

    it 're-uploads failed nodes still in the repo' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('web01'), 'new_rev')
    end

    # web02's file may live outside a tracked tree that changed since.
    it 'does not delete failed nodes no longer in the repo' do
      upload
      expect(knife).to have_received(:node_delete).with([])
    end

    it 'records only the re-uploaded nodes' do
      upload
      expect(read_node_checkpoint).to eq(['new_rev', ['web01']])
    end
  end

  # The diff and the re-upload list name the same node.
  context 'with an unverified node that also changed' do
    let(:changes) { { nodes: [change(:modified, 'web01')] } }

    before do
      write_node_checkpoint(%w[web01], 'rev123')
      allow(knife).to receive(:verify_node_upload).and_return(false)
    end

    it 'uploads it once' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('web01'), 'new_rev')
    end
  end

  # The list must be rewritten even when empty: a stale one would keep main
  # from ever finding nothing to do, and re-verify the same nodes every run.
  context 'with nodes from an upload that all verify' do
    before { write_node_checkpoint(%w[db01], 'rev123') }

    it 'clears the list for the next run' do
      upload
      expect(read_node_checkpoint).to eq(['new_rev', []])
    end
  end

  context 'when nodes are uploaded' do
    let(:changes) { { nodes: [change(:modified, 'web01')] } }

    it 'records them for the next run to verify' do
      upload
      expect(read_node_checkpoint).to eq(['new_rev', ['web01']])
    end
  end

  context 'when ChefDiff rejects a revision' do
    before { allow(ChefDiff::Changeset).to receive(:new).and_raise(ChefDiff::Changeset::ReferenceError, 'unknown ref "gone"') }

    it 'logs a repo error and exits 2', :aggregate_failures do
      expect { upload }.to exit_with(2)
      expect(RunningSushi::Log).to have_received(:error).with(/Repo error.*unknown ref "gone"/)
    end
  end
end
