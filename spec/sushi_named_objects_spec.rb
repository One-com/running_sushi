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

# Nodes, clients and environments are uploaded or deleted by name, looking
# at every file of their kind in Git, not at the one file in the diff.
# ChefDiff parses the paths for real; git and the Chef Server are faked.
describe 'chef_upload by name' do
  subject(:upload) { chef_upload(knife, repo, 'old_rev', 'new_rev') }

  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) do
    instance_double(ChefDiff::Repo::Git, changes: diff,
                                         files: git_files.map { |path| { path: path, status: :created } })
  end
  let(:knife) do
    instance_double(RunningSushi::Knife, check_uploads: nil, verify_node_upload: true,
                                         **KNIFE_WRITES.values.flatten.to_h { |m| [m, nil] })
  end

  def modified(*paths)
    paths.map { |path| { path: path, status: :modified } }
  end

  def deleted(*paths)
    paths.map { |path| { path: path, status: :deleted } }
  end

  before do
    RunningSushi::Config.master_path = tmpdir
    allow(RunningSushi::Log).to receive(:warn)
  end

  after { FileUtils.remove_entry(tmpdir) }

  # git mv nodes/pod1/a/web01.json nodes/pod1/b/web01.json
  context 'when a node file moved to another subdir' do
    let(:git_files) { ['nodes/pod1/b/web01.json'] }
    let(:diff) { deleted('nodes/pod1/a/web01.json') + modified('nodes/pod1/b/web01.json') }

    it 'uploads it from the new file' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('pod1/b/web01'), 'new_rev')
    end

    it 'does not delete it' do
      upload
      expect(knife).to have_received(:node_delete).with([])
    end
  end

  context 'when a changed node has two files in Git' do
    let(:git_files) { ['nodes/pod1/a/web01.json', 'nodes/pod1/b/web01.json'] }
    let(:diff) { modified('nodes/pod1/a/web01.json') }

    it 'fails naming both files' do
      expect { upload }.to raise_error(RunningSushi::GitState::DuplicateNameError,
                                       'nodes: node web01 is defined by more than one file: ' \
                                       'pod1/a/web01.json, pod1/b/web01.json')
    end

    it 'writes nothing to the server', :aggregate_failures do
      expect { upload }.to raise_error(RunningSushi::GitState::DuplicateNameError)
      KNIFE_WRITES.values.flatten.each { |m| expect(knife).not_to have_received(m) }
    end
  end

  # The re-upload list touches web01 although the diff does not.
  context 'when an unverified node has two files in Git' do
    let(:git_files) { ['nodes/a/web01.json', 'nodes/b/web01.json'] }
    let(:diff) { [] }

    before do
      write_node_checkpoint(['a/web01'], 'rev123')
      allow(knife).to receive(:verify_node_upload).and_return(false)
    end

    it { expect { upload }.to raise_error(RunningSushi::GitState::DuplicateNameError, /node web01 /) }
  end

  context 'when an unchanged node has two files in Git' do
    let(:git_files) { ['nodes/a/web01.json', 'nodes/b/web01.json', 'nodes/db01.json'] }
    let(:diff) { modified('nodes/db01.json') }

    it 'uploads the changed node' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('db01'), 'new_rev')
    end
  end

  # With pod_name, the other pods' files are not in the tracked tree.
  context 'with a pod name and the same node in another pod' do
    let(:git_files) { ['nodes/pod1/web01.json', 'nodes/pod2/web01.json'] }
    let(:diff) { modified('nodes/pod1/web01.json') }

    before { RunningSushi::Config.pod_name = 'pod1' }

    it 'uploads the pod one' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('web01'), 'new_rev')
    end
  end

  # A virtual pod's nodes come from its own dir only: not its parent's, not a
  # sibling's, and not vpod10's, which shares vpod1 as a string prefix.
  context 'with a virtual pod and the same node in its parent and siblings' do
    let(:git_files) do
      %w[nodes/pod1/web01.json nodes/pod1/vpod2/web01.json nodes/pod1/vpod10/web01.json
         nodes/pod1/vpod1/web01.json]
    end
    let(:diff) { modified('nodes/pod1/vpod1/web01.json') }

    before { RunningSushi::Config.pod_name = 'pod1/vpod1' }

    it 'uploads the virtual pod one' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('web01'), 'new_rev')
    end
  end

  context 'when a node and a client share a name' do
    let(:git_files) { ['nodes/web01.json', 'clients/web01.json'] }
    let(:diff) { modified('nodes/web01.json', 'clients/web01.json') }

    it 'uploads both', :aggregate_failures do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('web01'), 'new_rev')
      expect(knife).to have_received(:client_upload).with(full_names('web01'))
    end
  end

  { nodes: :node_delete, clients: :client_delete, environments: :environment_delete }.each do |dir, method|
    context "when the last #{dir} file of a name is deleted" do
      let(:git_files) { ["#{dir}/pod1/other.json"] }
      let(:diff) { deleted("#{dir}/pod1/sub/web01.json") }

      it "deletes it by name with #{method}" do
        upload
        expect(knife).to have_received(method).with([have_attributes(name: 'web01')])
      end
    end
  end

  context 'when the diff touches no role, node, client or environment' do
    let(:git_files) { [] }
    let(:diff) { modified('README.md') }

    it 'does not list the Git tree' do
      upload
      expect(repo).not_to have_received(:files)
    end
  end

  context 'with an unverified node moved since its upload' do
    let(:git_files) { ['nodes/pod1/b/web01.json'] }
    let(:diff) { [] }

    before do
      write_node_checkpoint(['pod1/a/web01'], 'rev123')
      allow(knife).to receive(:verify_node_upload).and_return(false)
    end

    it 'uploads it from the new file' do
      upload
      expect(knife).to have_received(:node_upload).with(full_names('pod1/b/web01'), 'new_rev')
    end
  end
end
