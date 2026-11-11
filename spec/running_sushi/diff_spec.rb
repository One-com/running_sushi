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

require_relative '../spec_helper'
require 'chef_diff/changeset'
require 'running_sushi/diff'

# The diff mode's planning, with the Changesets, the lazy Git listing and
# the Knife as verifying doubles. sushi_chef_upload_spec.rb and its
# siblings cover the same rules end to end through bin/running-sushi.
describe RunningSushi::Diff do
  def item(id, kind: :roles, change: nil)
    RunningSushi::GitState::Item.new(id: id, kind: kind, change: change)
  end

  # A ChefDiff change of the file +full_name+ (without .json).
  def change(full_name, status: :modified)
    ChefDiff::Changes::Change.new.tap do |c|
      c.status = status
      c.name = full_name
    end
  end

  def name_refs(*names)
    names.map { |name| RunningSushi::Knife::NameRef.new(name) }
  end

  # A Changeset double holding +changes+ (kind => changes), the other kinds
  # empty.
  def changeset(**changes)
    kinds = %i[cookbooks roles roles_local databags nodes environments clients]
    instance_double(ChefDiff::Changeset, **kinds.to_h { |kind| [kind, changes.fetch(kind, [])] })
  end

  # The +tree+ argument: returns the Changeset +listing+ when called.
  def tree_of(listing)
    instance_double(Proc, call: listing)
  end

  describe '.role_changes' do
    subject(:roles) { described_class.role_changes(diff, tree, local_roles: local_roles) }

    let(:tree) { tree_of(changeset(roles: [global], roles_local: [local])) }
    let(:global) { change('sub/web') }
    let(:local) { change('pod1/web') }
    let(:local_roles) { true }

    context 'when the global file of a role with a local file changed' do
      let(:diff) { changeset(roles: [global]) }

      it 'uploads the local file' do
        expect(roles).to eq([{ roles: [], roles_local: [local] }, []])
      end
    end

    context 'without local roles' do
      let(:diff) { changeset(roles: [global]) }
      let(:local_roles) { false }

      it 'uploads the global file' do
        expect(roles).to eq([{ roles: [global], roles_local: [] }, []])
      end
    end

    context 'when the last file of a role is deleted' do
      let(:diff) { changeset(roles: [change('db', status: :deleted)]) }

      it 'deletes the role by name' do
        expect(roles).to eq([{ roles: [], roles_local: [] }, name_refs('db')])
      end
    end

    context 'when the diff touched no role' do
      let(:diff) { changeset }

      it 'does not list the tree' do
        roles
        expect(tree).not_to have_received(:call)
      end
    end
  end

  describe '.named_changes' do
    subject(:named) { described_class.named_changes(:nodes, diff_changes, tree, extra_names: extra_names) }

    let(:tree) { tree_of(changeset(nodes: in_git)) }
    let(:in_git) { [] }
    let(:extra_names) { [] }

    # git mv nodes/a/web01.json nodes/b/web01.json
    context 'when a file moved to another subdir' do
      let(:in_git) { [change('b/web01')] }
      let(:diff_changes) { [change('a/web01', status: :deleted), change('b/web01', status: :modified)] }

      it 'uploads from the new file and deletes nothing' do
        expect(named).to eq([in_git, []])
      end
    end

    context 'when the last file of a name is deleted' do
      let(:diff_changes) { [change('web01', status: :deleted)] }

      it { is_expected.to eq([[], name_refs('web01')]) }
    end

    context 'with an extra name that has no file' do
      let(:diff_changes) { [] }
      let(:extra_names) { ['web01'] }

      it 'neither uploads nor deletes it' do
        expect(named).to eq([[], []])
      end
    end

    context 'with an extra name that has a file' do
      let(:in_git) { [change('web01')] }
      let(:diff_changes) { [] }
      let(:extra_names) { ['web01'] }

      it { is_expected.to eq([in_git, []]) }
    end

    context 'when nothing is touched' do
      let(:diff_changes) { [] }

      it 'does not list the tree' do
        named
        expect(tree).not_to have_received(:call)
      end
    end
  end

  describe '.changes_by_name' do
    subject(:changes) { described_class.changes_by_name(touched, items) }

    let(:global) { item('web', kind: :roles) }
    let(:local) { item('web', kind: :roles_local) }

    context 'when the global file changed under a local one' do
      let(:touched) { ['web'] }
      # Local first, so a last-wins lookup can't pass.
      let(:items) { [local, global] }

      it { is_expected.to eq([[local], []]) }
    end

    context 'when the local file is gone' do
      let(:touched) { ['web'] }
      let(:items) { [global] }

      it { is_expected.to eq([[global], []]) }
    end

    # git mv roles/a/web.json roles/b/web.json: the diff deletes and creates
    # the name web, and the role must be uploaded, never deleted.
    context 'when a role file moved to another subdir' do
      let(:touched) { %w[web web] }
      let(:items) { [global] }

      it { is_expected.to eq([[global], []]) }
    end

    context 'when no file claims the name' do
      let(:touched) { %w[web web] }
      let(:items) { [] }

      it { is_expected.to eq([[], ['web']]) }
    end

    context 'with a role the diff did not touch' do
      let(:touched) { [] }
      let(:items) { [global] }

      it { is_expected.to eq([[], []]) }
    end

    context 'when a touched name has two global files' do
      let(:touched) { ['web'] }
      let(:items) { [item('web', change: change('a/web')), item('web', change: change('b/web'))] }

      it { expect { changes }.to raise_error(RunningSushi::GitState::DuplicateNameError) }
    end

    # Reconcile reports it; the diff path only fails for names it uploads.
    context 'when an untouched name has two global files' do
      let(:touched) { ['db'] }
      let(:items) { [item('db'), item('web', change: change('a/web')), item('web', change: change('b/web'))] }

      it { is_expected.to eq([[item('db')], []]) }
    end
  end

  describe '.cookbook_deletes' do
    subject { described_class.cookbook_deletes(deleted, in_git: in_git, on_server: on_server) }

    let(:in_git) { [%w[nginx 2.0.0]] }
    let(:on_server) { [%w[nginx 1.0.0], %w[nginx 2.0.0], %w[apache 1.0.0]] }

    context 'with an unversioned dir' do
      let(:deleted) { [['nginx', nil]] }

      it { is_expected.to eq([%w[nginx 1.0.0]]) }
    end

    context 'with a tagged dir' do
      let(:deleted) { [%w[nginx 1.0.0]] }

      it { is_expected.to eq([%w[nginx 1.0.0]]) }
    end

    # nginx-v2.0.0 deleted while the unversioned nginx has metadata 2.0.0.
    context 'with a tagged version another dir provides' do
      let(:deleted) { [%w[nginx 2.0.0]] }

      it { is_expected.to be_empty }
    end

    # Knife#cookbook_version_delete logs the 404, as for any delete.
    context 'with a tagged version not on the server' do
      let(:deleted) { [%w[nginx 3.0.0]] }

      it { is_expected.to eq([%w[nginx 3.0.0]]) }
    end

    context 'with an unversioned and a tagged dir of one version' do
      let(:deleted) { [['nginx', nil], %w[nginx 1.0.0]] }

      it { is_expected.to eq([%w[nginx 1.0.0]]) }
    end

    context 'with two unversioned dirs' do
      let(:deleted) { [['nginx', nil], ['apache', nil]] }

      it { is_expected.to eq([%w[apache 1.0.0], %w[nginx 1.0.0]]) }
    end

    context 'without deleted dirs' do
      let(:deleted) { [] }

      it { is_expected.to be_empty }
    end
  end

  describe '.deleted_cookbook_versions' do
    subject(:versions) { described_class.deleted_cookbook_versions(knife, deleted, tree) }

    let(:knife) do
      instance_double(RunningSushi::Knife, cookbook_ids: [%w[nginx 2.0.0]],
                                           server_cookbook_versions: [%w[nginx 1.0.0], %w[nginx 2.0.0]])
    end
    let(:pinned) { change('nginx-v2.0.0') }
    let(:tree) { tree_of(changeset(cookbooks: [pinned, change('apache')])) }

    before { allow(knife).to receive(:cookbook_info) { |c| [c.name.sub(/-v\d.*/, ''), nil] } }

    context 'with an unversioned dir deleted next to a pinned one' do
      let(:deleted) { [change('nginx', status: :deleted)] }

      it 'keeps the pinned version' do
        expect(versions).to eq([%w[nginx 1.0.0]])
      end

      it 'loads only the dirs named after a deleted cookbook' do
        versions
        expect(knife).to have_received(:cookbook_ids).with([pinned])
      end
    end

    context 'without deleted dirs' do
      let(:deleted) { [] }

      it { is_expected.to be_empty }

      it 'does not list the tree' do
        versions
        expect(tree).not_to have_received(:call)
      end

      it 'does not read the server' do
        versions
        expect(knife).not_to have_received(:server_cookbook_versions)
      end
    end
  end

  describe '.plan' do
    subject(:plan) do
      described_class.plan(diff, tree, instance_double(RunningSushi::Knife), local_roles: true, extra_nodes: [])
    end

    let(:tree) { tree_of(in_git) }
    let(:in_git) { changeset }

    context 'with only cookbooks and databags added' do
      let(:cookbook) { change('nginx') }
      let(:databag) { change('users/alice') }
      let(:diff) { changeset(cookbooks: [cookbook], databags: [databag]) }

      it 'does not list the tree' do
        plan
        expect(tree).not_to have_received(:call)
      end

      it 'uploads them' do
        expect(plan.uploads).to include(cookbooks: [cookbook], databags: [databag])
      end
    end

    context 'with a databag deleted' do
      let(:gone) { change('users/bob', status: :deleted) }
      let(:diff) { changeset(databags: [gone]) }

      it 'deletes it' do
        expect(plan.deletes).to include(databags: [gone])
      end
    end

    # Decided by name like nodes, not per file like databags.
    context 'when an environment and a client moved subdir' do
      let(:env) { change('b/prod', status: :modified) }
      let(:client) { change('b/web01', status: :modified) }
      let(:in_git) { changeset(environments: [env], clients: [client]) }
      let(:diff) do
        changeset(environments: [change('a/prod', status: :deleted), env],
                  clients: [change('a/web01', status: :deleted), client])
      end

      it 'deletes neither' do
        expect(plan.deletes).to include(environments: [], clients: [])
      end
    end

    context 'when a global role that loses to a local one changed' do
      let(:global) { change('web') }
      let(:local) { change('web') }
      let(:in_git) { changeset(roles: [global], roles_local: [local]) }
      let(:diff) { changeset(roles: [global]) }

      it 'uploads the local role' do
        expect(plan.uploads).to include(roles: [], roles_local: [local])
      end

      it 'still checks the global role' do
        expect(plan.checks).to include(roles: [global], roles_local: [local])
      end
    end
  end

  describe '.report' do
    subject(:lines) { described_class.report(plan) }

    let(:kinds) { %i[cookbooks roles roles_local databags nodes environments clients] }
    # A distinct list per slot, so a label showing another slot's list fails.
    let(:plan) do
      described_class::Plan.new(uploads: kinds.to_h { |kind| [kind, ["up_#{kind}"]] },
                                deletes: (kinds - [:roles_local]).to_h { |kind| [kind, ["rm_#{kind}"]] },
                                deleted_cookbooks: ['rm_dirs'], checks: {})
    end
    let(:expected) do
      ['Added cookbooks: ["up_cookbooks"]', 'Deleted cookbooks: ["rm_dirs"]',
       'Deleted cookbook versions: ["rm_cookbooks"]', 'Added roles: ["up_roles"]', 'Deleted roles: ["rm_roles"]',
       'Added local roles: ["up_roles_local"]', 'Added databags: ["up_databags"]',
       'Deleted databags: ["rm_databags"]', 'Added nodes: ["up_nodes"]', 'Deleted nodes: ["rm_nodes"]',
       'Added environments: ["up_environments"]', 'Deleted environments: ["rm_environments"]',
       'Added clients: ["up_clients"]', 'Deleted clients: ["rm_clients"]']
    end

    it 'logs each list under its label, in order' do
      expect(lines).to eq(expected)
    end
  end

  describe '.apply' do
    subject(:apply) { described_class.apply(knife, plan, 'rev') { calls << :yield } }

    let(:knife) { instance_double(RunningSushi::Knife) }
    let(:calls) { [] }
    let(:kinds) { %i[cookbooks roles roles_local databags nodes environments clients] }
    let(:plan) do
      described_class::Plan.new(uploads: kinds.to_h { |kind| [kind, [kind]] },
                                deletes: (kinds - [:roles_local]).to_h { |kind| [kind, [:"gone_#{kind}"]] },
                                deleted_cookbooks: [], checks: {})
    end

    before do
      KNIFE_WRITES.values.flatten.each { |write| allow(knife).to receive(write) { calls << write } }
    end

    it 'writes in the documented order' do
      apply
      expect(calls).to eq(%i[cookbook_version_delete cookbook_upload role_delete role_upload role_local_upload
                             databag_delete databag_upload node_delete node_upload yield
                             environment_delete environment_upload client_delete client_upload])
    end

    it 'stamps the uploaded nodes with the revision' do
      apply
      expect(knife).to have_received(:node_upload).with([:nodes], 'rev')
    end

    it 'yields the uploaded nodes' do
      expect { |block| described_class.apply(knife, plan, 'rev', &block) }.to yield_with_args([:nodes])
    end
  end
end
