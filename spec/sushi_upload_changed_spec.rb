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

describe 'upload_changed' do
  before do
    RunningSushi::Config.master_path = '/var/chef/work'
    RunningSushi::Config.reponame = 'ops'
    RunningSushi::Config.pod_name = nil
    allow(RunningSushi::Log).to receive(:warn)
    allow(self).to receive(:chef_upload)
  end

  context 'with a repo at deadbeef' do
    let(:repo) { instance_double(ChefDiff::Repo::Git, head_rev: 'deadbeef') }
    let(:knife) { instance_double(RunningSushi::Knife) }

    before { allow(RunningSushi::Knife).to receive(:new).and_return(knife) }

    it 'calls chef_upload with both revs' do
      upload_changed(repo, 'old_rev')
      expect(self).to have_received(:chef_upload).with(knife, repo, 'old_rev', 'deadbeef')
    end

    it 'returns the head rev' do
      expect(upload_changed(repo, 'old_rev')).to eq('deadbeef')
    end

    # The repo paths are the Config defaults, joined to master_path/reponame.
    it 'points the knife at the checkout' do
      upload_changed(repo, 'old_rev')
      expect(RunningSushi::Knife).to have_received(:new).with(knife_dirs)
    end
  end

  def knife_dirs
    base = '/var/chef/work/ops'
    {
      logger: RunningSushi::Log, master_path: '/var/chef/work', base_dir: base,
      client_dir: "#{base}/clients", cookbook_dirs: ["#{base}/cookbooks"], databag_dir: "#{base}/data_bags",
      environment_dir: "#{base}/environments", node_dir: "#{base}/nodes", role_dir: "#{base}/roles",
      role_local_dir: "#{base}/roles_local"
    }
  end
end
