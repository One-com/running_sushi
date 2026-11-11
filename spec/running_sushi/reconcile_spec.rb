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
require 'running_sushi/knife'
require 'running_sushi/reconcile'

describe RunningSushi::Reconcile do
  def item(id, kind: :roles, change: nil)
    RunningSushi::GitState::Item.new(id: id, kind: kind, change: change)
  end

  describe '.diff' do
    subject(:drift) { described_class.diff(items, actual) }

    context 'when Git and the server match' do
      let(:items) { [item('web'), item('db')] }
      let(:actual) { %w[db web] }

      it { is_expected.to have_attributes(missing: [], extra: []) }
    end

    context 'with drift both ways' do
      let(:items) { [item('web'), item('db')] }
      let(:actual) { %w[web stray] }

      it { is_expected.to have_attributes(missing: ['db'], extra: ['stray']) }
    end

    context 'with the same role global and local' do
      let(:items) { [item('web'), item('web', kind: :roles_local)] }
      let(:actual) { [] }

      it { is_expected.to have_attributes(missing: ['web']) }
    end

    context 'with an old version of a cookbook' do
      let(:items) { [item(%w[nginx 1.2.0])] }
      let(:actual) { [%w[nginx 1.1.0], %w[nginx 1.2.0]] }

      it { is_expected.to have_attributes(missing: [], extra: [%w[nginx 1.1.0]]) }
    end
  end

  describe '.guard' do
    subject(:reason) { described_class.guard(described_class.diff(items, actual), empty_dirs) }

    let(:items) { [item('web')] }
    let(:empty_dirs) { ['roles'] }

    context 'without extras' do
      let(:actual) { ['web'] }

      it { is_expected.to be_nil }
    end

    context 'with extras and an empty dir' do
      let(:actual) { ['stray'] }

      it { is_expected.to eq('nothing in Git under roles') }
    end

    context 'with only extras and no empty dir' do
      let(:empty_dirs) { [] }
      let(:actual) { (1..50).map { |n| "stray#{n}" } }

      it { is_expected.to be_nil }
    end
  end

  describe '.checks' do
    subject(:checks) do
      described_class.checks({ cookbooks: cookbooks, roles: roles, roles_local: [local_db] },
                             { cookbook_dirs: %w[cookbooks site-cookbooks], role_dir: 'roles' },
                             cookbooks: [%w[nginx 1.1.0]], roles: ['stray'])
    end

    let(:nginx) { item(%w[nginx 1.2.0], kind: :cookbooks, change: cookbook_change('nginx')) }
    let(:app) { item(%w[app 3.0.1], kind: :cookbooks, change: cookbook_change('app', 'site-cookbooks')) }
    let(:local_db) { item('db', kind: :roles_local) }
    let(:cookbooks) { [nginx, app] }
    let(:roles) { [item('web')] }

    context 'with files in every guarded dir' do
      it 'compares global and local roles as one type' do
        expect(checks.last).to have_attributes(type: :roles, items: [*roles, local_db])
      end

      it 'blocks no deletes' do
        expect(checks.map(&:blocked)).to eq([nil, nil])
      end
    end

    # Per dir, not per type: cookbooks/ still having files must not hide
    # that site-cookbooks/ lost all of its.
    context 'with one of two cookbook dirs empty in Git' do
      let(:cookbooks) { [nginx] }

      it 'blocks the cookbook deletes' do
        expect(checks.first.blocked).to eq('nothing in Git under site-cookbooks')
      end
    end

    # Local roles must not count for the role dir, or a checkout that lost
    # roles/ would delete every global role on the server.
    context 'with only local roles in Git' do
      let(:roles) { [] }

      it 'blocks the role deletes' do
        expect(checks.last.blocked).to eq('nothing in Git under roles')
      end
    end

    context 'with the validators and chef-webui on the server' do
      it 'never counts them as extra' do
        clients = described_class.checks({ clients: [item('web01', kind: :clients)] }, { client_dir: 'clients' },
                                         clients: %w[web01 acme-validator chef-validator chef-webui stray]).first
        expect(clients.drift.extra).to eq(['stray'])
      end
    end

    # Uploading _default fails on the Chef Server, and re-uploading a
    # validator destroys and recreates it.
    context 'with a file in Git for a built-in object' do
      it 'leaves it out of Git too', :aggregate_failures do
        environments = described_class.checks({ environments: [item('_default', kind: :environments)] },
                                              { environment_dir: 'environments' }, environments: []).first
        in_git = %w[acme-validator validator].map { |id| item(id, kind: :clients) }
        clients = described_class.checks({ clients: in_git }, { client_dir: 'clients' }, clients: []).first
        expect([environments.drift.missing, clients.drift.missing]).to eq([[], ['validator']])
      end
    end
  end

  describe '.report' do
    subject(:lines) do
      described_class.report(described_class.check(:cookbooks, items: items, actual: actual, empty_dirs: empty_dirs))
    end

    let(:empty_dirs) { [] }

    context 'with drift' do
      let(:items) { [item(%w[nginx 1.2.0], kind: :cookbooks), item(%w[app 3.0.1], kind: :cookbooks)] }
      let(:actual) { [%w[nginx 1.1.0], %w[app 3.0.1]] }

      it 'logs each item' do
        expect(lines.first(2)).to eq(
          [[:warn, 'Reconcile: missing cookbook nginx 1.2.0'],
           [:warn, 'Reconcile: extra cookbook nginx 1.1.0']]
        )
      end

      it 'logs the counts last' do
        expect(lines.last).to eq([:warn, 'Reconcile: cookbook: 2 in Git, 2 on server, 1 missing, 1 extra'])
      end
    end

    context 'when nothing of the type is in Git' do
      let(:items) { [] }
      let(:empty_dirs) { ['cookbooks'] }
      let(:actual) { [%w[nginx 1.1.0]] }

      it 'logs that the deletes are blocked' do
        expect(lines).to include([:error, 'Reconcile: not deleting extra cookbooks: nothing in Git under cookbooks'])
      end
    end

    context 'without drift' do
      let(:items) { [item(%w[nginx 1.2.0], kind: :cookbooks)] }
      let(:actual) { [%w[nginx 1.2.0]] }

      it 'logs only the counts' do
        expect(lines).to eq([[:warn, 'Reconcile: cookbook: 1 in Git, 1 on server, 0 missing, 0 extra']])
      end
    end
  end

  describe '.apply' do
    subject(:apply) { described_class.apply(knife, checks, 'rev1') { nil } }

    let(:knife) do
      instance_double(RunningSushi::Knife, cookbook_upload: nil, role_upload: nil, role_local_upload: nil,
                                           cookbook_version_delete: nil, role_delete: nil, node_upload: nil,
                                           node_delete: nil)
    end
    let(:cookbooks) { [item(%w[nginx 1.2.0], kind: :cookbooks, change: :nginx_dir)] }
    let(:roles) do
      # Local first, so a last-wins lookup can't pass "prefers a role's local file".
      [item('web', kind: :roles_local, change: :web_local), item('web', kind: :roles, change: :web_global),
       item('db', kind: :roles, change: :db_global)]
    end
    let(:checks) do
      [described_class.check(:cookbooks, items: cookbooks, actual: [%w[nginx 1.1.0]], empty_dirs: []),
       described_class.check(:roles, items: roles, actual: ['stray'], empty_dirs: empty_role_dirs)]
    end
    let(:empty_role_dirs) { [] }

    it 'uploads the missing cookbook version' do
      apply
      expect(knife).to have_received(:cookbook_upload).with([:nginx_dir])
    end

    it "prefers a role's local file" do
      apply
      expect(knife).to have_received(:role_local_upload).with([:web_local])
    end

    it 'uploads a global-only role' do
      apply
      expect(knife).to have_received(:role_upload).with([:db_global])
    end

    it 'deletes only the extra cookbook version' do
      apply
      expect(knife).to have_received(:cookbook_version_delete).with([%w[nginx 1.1.0]])
    end

    it 'deletes the extra role' do
      apply
      expect(knife).to have_received(:role_delete).with([RunningSushi::Knife::NameRef.new('stray')])
    end

    it 'uploads everything before it deletes' do
      calls = []
      KNIFE_WRITES.values.flatten.each { |write| allow(knife).to receive(write) { calls << write } }
      apply
      expect(calls.first(3)).to contain_exactly(:cookbook_upload, :role_upload, :role_local_upload)
    end

    context 'when the guard blocks a type' do
      let(:roles) { [] }
      let(:empty_role_dirs) { ['roles'] }

      it 'deletes nothing of it' do
        apply
        expect(knife).not_to have_received(:role_delete)
      end

      it 'still applies the other types' do
        apply
        expect(knife).to have_received(:cookbook_version_delete).with([%w[nginx 1.1.0]])
      end
    end

    context 'with a missing node' do
      let(:checks) do
        [described_class.check(:nodes, items: [item('web01', kind: :nodes, change: :web01_file)], actual: [],
                                       empty_dirs: [])]
      end

      it 'stamps it with the revision' do
        apply
        expect(knife).to have_received(:node_upload).with([:web01_file], 'rev1')
      end

      it 'yields it for verification' do
        expect { |probe| described_class.apply(knife, checks, 'rev1', &probe) }.to yield_with_args([:web01_file])
      end
    end
  end
end
