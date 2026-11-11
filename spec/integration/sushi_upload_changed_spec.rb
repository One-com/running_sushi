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

# The diff path end to end: a real git repo under a tmpdir, the real
# ChefDiff::Changeset and Knife (via checkout_knife), and the ChefZero
# server. The unit specs in spec/sushi_chef_upload_spec.rb fake the
# changeset and the Knife; these check that the directories, names and
# revisions the three exchange actually line up. Only RunningSushi::Log is
# stubbed, to keep Syslog out of the run.

require_relative 'integration_helper'

# Every fixture whose contents match its path, one per kind. Local roles are
# left out: without pod_name they are ignored, so they get their own context.
CONSISTENT_FIXTURES = %w[
  cookbooks/test-cookbook roles/test-role.json data_bags/my-bag/my-item.json
  nodes/web01.json environments/test-env.json clients/test-client.json
].freeze

# server_objects of a server holding none of the fixtures.
EMPTY_SERVER = { cookbooks: [], roles: [], data_bags: {}, nodes: [], environments: [], clients: [] }.freeze

describe 'upload_changed' do
  subject(:upload) { upload_changed(repo, checkpoint) }

  let(:tmpdir) { Dir.mktmpdir }
  let(:repo_dir) { File.join(tmpdir, 'ops') }
  let(:repo) { fetch_repo }
  let(:checkpoint) { nil }

  # A role file in the repo whose description tells the copies apart.
  def write_role(path, description)
    file = File.join(repo_dir, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, JSON.generate(name: File.basename(path, '.json'), description: description))
  end

  # What the server holds of each kind. chef-zero always has the _default
  # environment and the chef-validator and chef-webui clients, so they are
  # left out.
  def server_objects
    { cookbooks: checkout_knife.server_cookbook_versions, roles: Chef::Role.list.keys.sort,
      data_bags: server_data_bags, nodes: Chef::Node.list.keys,
      environments: Chef::Environment.list.keys - ['_default'],
      clients: Chef::ApiClientV1.list.keys - %w[chef-validator chef-webui] }
  end

  def cookbook_versions
    checkout_knife.server_cookbook_versions
  end

  # { bag => [item ids] }
  def server_data_bags
    Chef::DataBag.list.keys.to_h { |bag| [bag, Chef::DataBag.load(bag).keys] }
  end

  def node_checkpoint(name)
    Chef::Node.load(name).normal['running_sushi']['checkpoint']
  end

  before do
    RunningSushi::Config.master_path = tmpdir
    git(tmpdir, 'init', '-q', 'ops')
    %i[warn info debug error].each { |level| allow(RunningSushi::Log).to receive(level) }
  end

  after { FileUtils.remove_entry(tmpdir) }

  context 'without a checkpoint' do
    let!(:head) do
      add_fixtures(repo_dir, CONSISTENT_FIXTURES)
      commit_all(repo_dir)
    end

    it 'uploads every object in the repo' do
      upload
      expect(server_objects).to eq(
        cookbooks: [%w[test-cookbook 1.0.0]], roles: %w[test-role], data_bags: { 'my-bag' => ['my-item'] },
        nodes: ['web01'], environments: ['test-env'], clients: ['test-client']
      )
    end

    it 'returns the head revision' do
      expect(upload).to eq(head)
    end

    it 'stamps the nodes with the head revision' do
      upload
      expect(node_checkpoint('web01')).to eq(head)
    end

    it 'records the nodes for the next run to verify' do
      upload
      expect(read_node_checkpoint).to eq([head, ['web01']])
    end
  end

  # The base commit is uploaded in full first, as a previous run would have;
  # each context then commits one change on top. The subject reads
  # checkpoint, which LetSetup can't see; it must be eager so the base
  # commit comes before the inner contexts' commits.
  context 'with a checkpoint' do
    let!(:checkpoint) do # rubocop:disable RSpec/LetSetup
      add_fixtures(repo_dir, CONSISTENT_FIXTURES)
      commit_all(repo_dir).tap { upload_changed(repo, nil) }
    end

    context 'when a role is edited' do
      before do
        write_role('roles/test-role.json', 'edited')
        commit_all(repo_dir)
      end

      it 'updates it on the server' do
        upload
        expect(Chef::Role.load('test-role').description).to eq('edited')
      end
    end

    context 'when files of every kind are deleted' do
      before do
        FileUtils.rm_r(CONSISTENT_FIXTURES.map { |f| File.join(repo_dir, f) })
        commit_all(repo_dir)
      end

      # Chef's knife UI reports the cookbook delete on the real STDERR.
      it 'deletes them from the server' do
        expect { upload }.to change { server_objects }.to(EMPTY_SERVER)
                                                      .and output(anything).to_stderr_from_any_process
      end
    end

    context 'when nothing changed' do
      it 'leaves the server as it was' do
        expect { upload }.not_to(change { server_objects })
      end
    end
  end

  # Deleting an unversioned cookbook dir must only delete the server versions
  # no other dir in Git still provides, or nodes pinned to a tagged version
  # break until the next --reconcile.
  context 'with an unversioned cookbook next to a pinned version' do
    let!(:checkpoint) do # rubocop:disable RSpec/LetSetup -- as in 'with a checkpoint'
      add_fixtures(repo_dir, %w[cookbooks/test-cookbook cookbooks/test-cookbook-v2.0.0])
      commit_all(repo_dir).tap { upload_changed(repo, nil) }
    end

    context 'when it is renamed to its version tag' do
      before do
        git(repo_dir, 'mv', 'cookbooks/test-cookbook', 'cookbooks/test-cookbook-v1.0.0')
        commit_all(repo_dir)
      end

      it 'keeps every version' do
        upload
        expect(cookbook_versions).to contain_exactly(%w[test-cookbook 1.0.0], %w[test-cookbook 2.0.0])
      end
    end

    context 'when it is deleted' do
      before do
        FileUtils.rm_r(File.join(repo_dir, 'cookbooks/test-cookbook'))
        commit_all(repo_dir)
      end

      # Chef's knife UI reports the cookbook delete on the real STDERR.
      it 'deletes only its own version' do
        expect { upload }.to change { cookbook_versions }.to([%w[test-cookbook 2.0.0]])
                                                         .and output(anything).to_stderr_from_any_process
      end
    end
  end

  # Git can hold a cookbook the current Chef can't load, untouched by any
  # diff: after a Chef upgrade, or once its path joins cookbook_paths, as
  # here. Its metadata has no name, so CookbookVersionLoader#load! raises.
  context 'with an unloadable cookbook in Git' do
    let!(:checkpoint) do # rubocop:disable RSpec/LetSetup -- as in 'with a checkpoint'
      add_fixtures(repo_dir, %w[cookbooks/test-cookbook])
      FileUtils.mkdir_p(File.join(repo_dir, 'site-cookbooks/broken'))
      File.write(File.join(repo_dir, 'site-cookbooks/broken/metadata.rb'), "version '1.0.0'\n")
      commit_all(repo_dir).tap { upload_changed(repo, nil) }
    end

    before do
      RunningSushi::Config.cookbook_paths = %w[cookbooks site-cookbooks]
      FileUtils.rm_r(File.join(repo_dir, 'cookbooks/test-cookbook'))
      commit_all(repo_dir)
    end

    # Chef's knife UI reports the cookbook delete on the real STDERR.
    it 'still deletes another cookbook' do
      expect { upload }.to change { cookbook_versions }.to([])
                                                       .and output(anything).to_stderr_from_any_process
    end
  end

  # A local role overrides the global role of the same name on this server;
  # the role must never disappear from the server while either file exists.
  # Local roles only apply with a pod_name; set before the eager checkpoint.
  context 'with a local role shadowing a global one' do
    before { RunningSushi::Config.pod_name = 'pod1' }

    let!(:checkpoint) do # rubocop:disable RSpec/LetSetup -- as in 'with a checkpoint'
      write_role('roles/web.json', 'global')
      write_role('roles_local/pod1/web.json', 'local')
      commit_all(repo_dir).tap { upload_changed(repo, nil) }
    end

    def web_role
      Chef::Role.load('web').description
    end

    context 'when the global role is edited' do
      before do
        write_role('roles/web.json', 'global v2')
        commit_all(repo_dir)
      end

      it 'keeps the local role' do
        upload
        expect(web_role).to eq('local')
      end
    end

    context 'when the global role is deleted' do
      before do
        File.delete(File.join(repo_dir, 'roles/web.json'))
        commit_all(repo_dir)
      end

      it 'keeps the local role' do
        upload
        expect(web_role).to eq('local')
      end
    end

    context 'when the local role is deleted' do
      before do
        File.delete(File.join(repo_dir, 'roles_local/pod1/web.json'))
        commit_all(repo_dir)
      end

      it 'restores the global role' do
        upload
        expect(web_role).to eq('global')
      end
    end
  end

  # Without pod_name the server serves every pod, so one pod's local role
  # must not reach it: roles_local/ is ignored as if it were absent.
  context 'with local roles and no pod name' do
    before do
      write_role('roles/web.json', 'global')
      write_role('roles_local/web.json', 'local')
      write_role('roles_local/db.json', 'local')
      commit_all(repo_dir)
    end

    it 'keeps the global role over the local one' do
      upload
      expect(Chef::Role.load('web').description).to eq('global')
    end

    it 'does not upload local-only roles' do
      upload
      expect(Chef::Role.list.keys).to eq(['web'])
    end
  end

  # chef-client saves the node back at the end of its run; one that started
  # before the upload overwrites it with the old content. The next run finds
  # the stale checkpoint stamp and uploads the node again.
  context 'when a node upload did not stick' do
    let!(:checkpoint) do
      add_fixtures(repo_dir, ['nodes/web01.json'])
      commit_all(repo_dir).tap { upload_changed(repo, nil) }
    end

    before do
      Chef::Node.load('web01').tap { |node| node.normal['running_sushi']['checkpoint'] = 'stale' }.save
    end

    it 'uploads the node again' do
      upload
      expect(node_checkpoint('web01')).to eq(checkpoint)
    end

    context 'when the node file is deleted since' do
      before do
        File.delete(File.join(repo_dir, 'nodes/web01.json'))
        commit_all(repo_dir)
      end

      it 'deletes the node instead' do
        upload
        expect(Chef::Node.list).to be_empty
      end
    end
  end

  # Pod dirs are per-server subdirs of the node, client, environment and
  # local role dirs.
  context 'with a pod name' do
    before do
      RunningSushi::Config.pod_name = 'pod1'
      add_fixtures(repo_dir, { 'environments/test-env.json' => 'environments/pod1/test-env.json',
                               'nodes/web01.json' => 'nodes/pod2/web01.json' })
      commit_all(repo_dir)
    end

    it 'uploads from its own pod dirs' do
      upload
      expect(Chef::Environment.list.keys).to include('test-env')
    end

    it 'skips the dirs of other pods' do
      upload
      expect(Chef::Node.list).to be_empty
    end
  end

  # Mismatches must fail the run before the first write, so a renamed file
  # never gets its old object deleted without a replacement.
  context 'with a file that contradicts its path' do
    before do
      add_fixtures(repo_dir, %w[roles/test-role.json roles/misnamed-role.json])
      commit_all(repo_dir)
    end

    it 'fails naming the file' do
      expect { upload }.to raise_error(RunningSushi::Knife::MismatchError, %r{roles/misnamed-role\.json})
    end

    it 'writes nothing to the server' do
      expect { upload }.to raise_error(RunningSushi::Knife::MismatchError)
        .and(not_change { Chef::Role.list.keys })
    end
  end

  context 'when in dry-run mode' do
    before do
      RunningSushi::Config.dry_run = true
      add_fixtures(repo_dir, CONSISTENT_FIXTURES)
      commit_all(repo_dir)
    end

    it 'writes nothing to the server' do
      upload
      expect(server_objects).to eq(EMPTY_SERVER)
    end

    it 'records no nodes to verify' do
      upload
      expect(read_node_checkpoint).to eq([nil, []])
    end

    it 'still fails on a mismatched file' do
      add_fixtures(repo_dir, ['nodes/misnamed-node.json'])
      commit_all(repo_dir)
      expect { upload }.to raise_error(RunningSushi::Knife::MismatchError, /misnamed-node/)
    end
  end

  context 'with a checkpoint unknown to the repo' do
    let(:checkpoint) { '0' * 40 }

    before do
      add_fixtures(repo_dir, ['roles/test-role.json'])
      commit_all(repo_dir)
    end

    it 'exits 2' do
      expect { upload }.to exit_with(2)
    end
  end
end
