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

# Reconcile against chef-zero, reading the real fixtures. "In Git" is
# cookbooks test-cookbook (1.0.0) and test-cookbook-v2.0.0, role test-role,
# local role local-role, environment test-env, node web01, client
# test-client and data bag item my-bag/my-item. The misnamed-* fixtures are
# left out, except where a mismatch is the point.

require_relative '../integration_helper'
require 'running_sushi/reconcile'

describe RunningSushi::Reconcile do
  # Stands in for a ChefDiff::Changeset built with a nil start revision.
  let(:roles_in_git) { %w[test-role] }
  let(:changeset) do
    instance_double(
      ChefDiff::Changeset,
      cookbooks: %w[test-cookbook test-cookbook-v2.0.0].map { |dir| cookbook_change(dir) },
      roles: roles_in_git.map { |name| make_change(name) },
      roles_local: [make_change('local-role')],
      environments: [make_change('test-env')],
      nodes: [make_change('web01')],
      clients: [make_change('test-client')],
      databags: [databag_change('my-bag', 'my-item')]
    )
  end
  let(:logger) { instance_double(Logger, warn: nil, error: nil) }
  let(:knife) { build_knife }
  let(:local_roles) { true }

  # The directories +changeset+ stands for; no context varies them.
  def locations
    { cookbook_dirs: ['cookbooks'], role_dir: 'roles', role_local_dir: 'roles_local',
      environment_dir: 'environments', node_dir: 'nodes', client_dir: 'clients',
      databag_dir: 'data_bags' }
  end

  # The types compared; a method, like #locations, to stay under the
  # memoized-helper limit.
  def types
    %i[cookbooks roles environments nodes clients databags]
  end

  # Drift: test-cookbook 2.0.0 and local-role missing, test-cookbook 0.9.0
  # and stray-role extra; test-env missing and stray-env extra. chef-zero
  # adds the _default environment, which has no file in Git. web01 missing
  # and stray-node extra. my-bag/my-item missing, my-bag/stray-item and
  # old-bag/old-item extra. test-client missing and stray-client extra;
  # chef-zero adds the chef-validator and chef-webui clients.
  before do
    knife.cookbook_upload([cookbook_change('test-cookbook')])
    CHEF_ZERO_SERVER.load_data(
      'cookbooks' => { 'test-cookbook-0.9.0' => { 'metadata.rb' => "name 'test-cookbook'\nversion '0.9.0'" } },
      'roles' => %w[test-role stray-role].to_h { |name| [name, { 'name' => name }] },
      'environments' => { 'stray-env' => { 'name' => 'stray-env' } },
      'nodes' => { 'stray-node' => { 'name' => 'stray-node' } },
      'clients' => { 'stray-client' => { 'name' => 'stray-client' } },
      'data' => { 'my-bag' => { 'stray-item' => {} }, 'old-bag' => { 'old-item' => {} } }
    )
  end

  describe '.compare' do
    subject(:compare) do
      described_class.compare(knife, changeset, logger, locations, local_roles: local_roles, types: types)
    end

    it 'reports the drift', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: missing cookbook test-cookbook 2.0.0')
      expect(logger).to have_received(:warn).with('Reconcile: extra cookbook test-cookbook 0.9.0')
      expect(logger).to have_received(:warn).with('Reconcile: missing role local-role')
      expect(logger).to have_received(:warn).with('Reconcile: extra role stray-role')
    end

    it 'reports the environment drift', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: missing environment test-env')
      expect(logger).to have_received(:warn).with('Reconcile: extra environment stray-env')
    end

    it 'reports the node drift', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: missing node web01')
      expect(logger).to have_received(:warn).with('Reconcile: extra node stray-node')
    end

    it 'reports the client drift', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: missing client test-client')
      expect(logger).to have_received(:warn).with('Reconcile: extra client stray-client')
    end

    it 'reports the data bag drift', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: missing data bag item my-bag my-item')
      expect(logger).to have_received(:warn).with('Reconcile: extra data bag item my-bag stray-item')
      expect(logger).to have_received(:warn).with('Reconcile: extra data bag item old-bag old-item')
    end

    it 'logs the counts per type', :aggregate_failures do
      compare
      expect(logger).to have_received(:warn).with('Reconcile: cookbook: 2 in Git, 2 on server, 1 missing, 1 extra')
      expect(logger).to have_received(:warn).with('Reconcile: role: 2 in Git, 2 on server, 1 missing, 1 extra')
      expect(logger).to have_received(:warn).with('Reconcile: environment: 1 in Git, 1 on server, 1 missing, 1 extra')
    end

    context 'with only cookbooks selected' do
      def types
        %i[cookbooks]
      end

      it 'compares nothing else' do
        compare
        expect(logger).to have_received(:warn).with(/ in Git, /).once
      end
    end

    it 'changes nothing on the server', :aggregate_failures do
      compare
      expect(Chef::Role.list.keys).to contain_exactly('test-role', 'stray-role')
      expect(knife.server_cookbook_versions).to contain_exactly(%w[test-cookbook 0.9.0], %w[test-cookbook 1.0.0])
    end

    context 'with a file that contradicts its path' do
      let(:roles_in_git) { %w[test-role misnamed-role] }

      it 'fails naming the file' do
        expect { compare }.to raise_error(RunningSushi::Knife::MismatchError, %r{roles/misnamed-role\.json})
      end
    end

    # The same fixture twice stands in for roles/a/test-role.json and
    # roles/b/test-role.json.
    context 'with two global role files of one name' do
      let(:roles_in_git) { %w[test-role test-role] }

      it 'fails naming the role' do
        expect { compare }.to raise_error(RunningSushi::GitState::DuplicateNameError, /role test-role/)
      end
    end

    # Local roles must not count for the role dir, or a checkout that lost
    # roles/ would delete every global role on the server.
    context 'with only local roles in Git' do
      let(:roles_in_git) { [] }

      it 'blocks the role deletes' do
        compare
        expect(logger).to have_received(:error).with('Reconcile: not deleting extra roles: nothing in Git under roles')
      end
    end

    context 'without local roles' do
      let(:local_roles) { false }

      it 'leaves the local role out of Git' do
        compare
        expect(logger).to have_received(:warn).with('Reconcile: role: 1 in Git, 2 on server, 0 missing, 1 extra')
      end
    end
  end

  describe '.apply' do
    subject(:apply) do
      checks = described_class.compare(knife, changeset, logger, locations, local_roles: local_roles, types: types)
      described_class.apply(knife, checks, 'rev1') { nil }
    end

    it 'makes the server match Git', :aggregate_failures do
      apply
      expect(Chef::Role.list.keys).to contain_exactly('test-role', 'local-role')
      expect(Chef::Environment.list.keys).to contain_exactly('_default', 'test-env')
      expect(knife.server_cookbook_versions).to contain_exactly(%w[test-cookbook 1.0.0], %w[test-cookbook 2.0.0])
    end

    it 'makes nodes, clients, data bags match Git', :aggregate_failures do
      apply
      expect(Chef::Node.list.keys).to contain_exactly('web01')
      expect(Chef::ApiClientV1.list.keys).to contain_exactly('chef-validator', 'chef-webui', 'test-client')
      expect(knife.server_databag_items).to eq([%w[my-bag my-item]])
    end

    it 'deletes a data bag along with its last item' do
      apply
      expect(Chef::DataBag.list.keys).to contain_exactly('my-bag')
    end

    it 'stamps the uploaded node' do
      apply
      expect(Chef::Node.load('web01').normal['running_sushi']['checkpoint']).to eq('rev1')
    end

    it 'yields the uploaded node' do
      checks = described_class.compare(knife, changeset, logger, locations, local_roles: local_roles, types: types)
      expect { |probe| described_class.apply(knife, checks, 'rev1', &probe) }.to yield_with_args([make_change('web01')])
    end

    # A checkout that lost one of these dirs must not delete the whole type.
    { environments: %w[environments stray-env], nodes: %w[nodes stray-node], clients: %w[clients stray-client],
      databags: ['data_bags', %w[my-bag stray-item]] }.each do |kind, (dir, stray)|
      context "with no #{kind} in Git" do
        before { allow(changeset).to receive(kind).and_return([]) }

        it 'logs the blocked deletes and keeps the extras', :aggregate_failures do
          type = described_class::TYPES.fetch(kind)
          apply
          expect(logger).to have_received(:error)
            .with("Reconcile: not deleting extra #{type[:noun]}s: nothing in Git under #{dir}")
          expect(knife.public_send(type[:list])).to include(stray)
        end
      end
    end

    it 'finds nothing to do on the next run' do
      apply
      described_class.compare(knife, changeset, logger, locations, local_roles: local_roles, types: types)
      expect(logger).to have_received(:warn).with(/, 0 missing, 0 extra$/).exactly(6).times
    end
  end
end
