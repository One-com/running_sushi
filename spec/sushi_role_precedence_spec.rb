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

# A local role wins over the global role of the same name, wherever in its
# tree either file sits. ChefDiff parses the paths for real; git and the Chef
# Server are faked, and the checkout holds empty files. +server+ maps each
# role on the server to the file it was uploaded from.
describe 'chef_upload role precedence' do
  subject(:roles_after) do
    repo = instance_double(ChefDiff::Repo::Git, changes: diff,
                                                files: git_files.map { |path| { path: path, status: :created } })
    chef_upload(knife, repo, 'old_rev', 'new_rev')
    server
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:knife) { instance_double(RunningSushi::Knife, check_uploads: nil, role_upload: nil, role_local_upload: nil) }

  before do
    RunningSushi::Config.master_path = tmpdir
    git_files.each do |path|
      file = File.join(tmpdir, 'ops', path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, '{}')
    end
    allow(RunningSushi::Log).to receive(:warn)
    KNIFE_WRITES.values.flatten.each { |m| allow(knife).to receive(m) }
    # pod_config is read per call: contexts set pod_name after this block.
    { role_upload: -> { RunningSushi::Config.role_path }, role_local_upload: -> { pod_config.last } }
      .each do |method, dir|
        allow(knife).to receive(method) do |changes|
          changes.each { |c| server[File.basename(c.full_name)] = File.join(dir.call, "#{c.full_name}.json") }
        end
      end
    allow(knife).to receive(:role_delete) { |roles| roles.each { |role| server.delete(role.name) } }
  end

  after { FileUtils.remove_entry(tmpdir) }

  # [pod_name, global file, local file] of the role web.
  {
    'with both trees flat' => ['pod1', 'roles/web.json', 'roles_local/pod1/web.json'],
    'with a nested local role' => ['pod1', 'roles/web.json', 'roles_local/pod1/sub/web.json'],
    'with a nested global role' => ['pod1', 'roles/sub/web.json', 'roles_local/pod1/web.json']
  }.each do |layout, (pod, global, local)|
    context "when the global role is edited, #{layout}" do
      let(:git_files) { [global, local] }
      let(:diff) { [{ path: global, status: :modified }] }
      let(:server) { { 'web' => local } }

      before { RunningSushi::Config.pod_name = pod }

      it('keeps the local role') { is_expected.to eq('web' => local) }
    end

    context "when the global role is deleted, #{layout}" do
      let(:git_files) { [local] }
      let(:diff) { [{ path: global, status: :deleted }] }
      let(:server) { { 'web' => local } }

      before { RunningSushi::Config.pod_name = pod }

      it('keeps the local role') { is_expected.to eq('web' => local) }
    end
  end

  context 'when a nested global role is deleted' do
    let(:git_files) { [] }
    let(:diff) { [{ path: 'roles/sub/c.json', status: :deleted }] }
    let(:server) { { 'c' => 'roles/sub/c.json' } }

    it('deletes it') { is_expected.to be_empty }
  end

  context 'when a local role is deleted under a nested global one' do
    let(:git_files) { ['roles/sub/a.json'] }
    let(:diff) { [{ path: 'roles_local/pod1/a.json', status: :deleted }] }
    let(:server) { { 'a' => 'roles_local/pod1/a.json' } }

    before { RunningSushi::Config.pod_name = 'pod1' }

    it('restores the global role') { is_expected.to eq('a' => 'roles/sub/a.json') }
  end

  # Three roles, so a loop that skips every second one fails; old has no
  # global role and must still be deleted.
  context 'when several local roles are deleted' do
    let(:git_files) { %w[roles/db.json roles/web.json] }
    let(:diff) { %w[db web old].map { |name| { path: "roles_local/pod1/#{name}.json", status: :deleted } } }
    let(:server) { %w[db web old].to_h { |name| [name, "roles_local/pod1/#{name}.json"] } }

    before { RunningSushi::Config.pod_name = 'pod1' }

    it('restores the global roles only') { is_expected.to eq('db' => 'roles/db.json', 'web' => 'roles/web.json') }
  end

  # Without pod_name the local tree is ignored: the global role wins, and
  # changes to local files don't reach the server.
  context 'without pod_name' do
    let(:git_files) { %w[roles/web.json roles_local/pod1/web.json] }

    context 'when the global role is edited' do
      let(:diff) { [{ path: 'roles/web.json', status: :modified }] }
      let(:server) { { 'web' => 'roles_local/pod1/web.json' } }

      it('uploads the global role') { is_expected.to eq('web' => 'roles/web.json') }
    end

    context 'when a local role is edited' do
      let(:diff) { [{ path: 'roles_local/pod1/web.json', status: :modified }] }
      let(:server) { { 'web' => 'roles/web.json' } }

      it('keeps the global role') { is_expected.to eq('web' => 'roles/web.json') }
    end

    context 'when a local-only role is deleted' do
      let(:diff) { [{ path: 'roles_local/pod1/old.json', status: :deleted }] }
      let(:server) { { 'old' => 'roles_local/pod1/old.json' } }

      it('leaves it on the server') { is_expected.to eq('old' => 'roles_local/pod1/old.json') }
    end
  end
end
