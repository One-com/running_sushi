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

require_relative 'spec_helper'

describe 'path helpers' do
  before { RunningSushi::Config.master_path = '/var/chef/work' }

  describe 'checkpoint_path' do
    before { RunningSushi::Config.rev_checkpoint = 'rev' }

    it 'joins master_path and rev_checkpoint' do
      expect(checkpoint_path).to eq('/var/chef/work/rev')
    end
  end

  describe 'node_checkpoint_path' do
    before { RunningSushi::Config.node_checkpoint = 'nodes.json' }

    it 'joins master_path and node_checkpoint' do
      expect(node_checkpoint_path).to eq('/var/chef/work/nodes.json')
    end
  end

  describe 'pod_config' do
    subject { pod_config }

    before do
      RunningSushi::Config.node_path = 'nodes'
      RunningSushi::Config.client_path = 'clients'
      RunningSushi::Config.environment_path = 'environments'
      RunningSushi::Config.role_local_path = 'roles_local'
    end

    context 'without a pod_name' do
      before { RunningSushi::Config.pod_name = nil }

      it { is_expected.to eq(%w[nodes clients environments roles_local]) }
    end

    context 'with a pod_name' do
      before { RunningSushi::Config.pod_name = 'pod1' }

      it { is_expected.to eq(%w[nodes/pod1 clients/pod1 environments/pod1 roles_local/pod1]) }
    end

    context 'with a symbol pod_name' do
      before { RunningSushi::Config.pod_name = :pod2 }

      it { is_expected.to eq(%w[nodes/pod2 clients/pod2 environments/pod2 roles_local/pod2]) }
    end

    context 'with a virtual pod' do
      before { RunningSushi::Config.pod_name = 'pod1/vpod1' }

      it { is_expected.to eq(%w[nodes/pod1/vpod1 clients/pod1/vpod1 environments/pod1/vpod1 roles_local/pod1/vpod1]) }
    end
  end

  describe 'checkout_knife' do
    let(:absolute_dirs) do
      { base_dir: '/var/chef/work/repo',
        cookbook_dirs: %w[/var/chef/work/repo/cookbooks /var/chef/work/repo/site-cookbooks],
        role_dir: '/var/chef/work/repo/roles',
        node_dir: '/var/chef/work/repo/nodes' }
    end

    before do
      RunningSushi::Config.reponame = 'repo'
      RunningSushi::Config.pod_name = nil
      RunningSushi::Config.cookbook_paths = %w[cookbooks site-cookbooks]
      RunningSushi::Config.role_path = 'roles'
      RunningSushi::Config.node_path = 'nodes'
      allow(RunningSushi::Knife).to receive(:new)
    end

    it 'makes every changeset directory absolute under the checkout' do
      checkout_knife
      expect(RunningSushi::Knife).to have_received(:new).with(hash_including(absolute_dirs))
    end
  end
end
