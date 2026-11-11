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

# Whole runs of bin/running-sushi, as cron starts them: ARGV and a config
# file in, a clone or pull of an upstream git repo, the ChefZero server and
# the checkpoint file out. spec/sushi_main_spec.rb covers main's branches
# with every helper stubbed; this checks that the helpers hand each other
# the right state across a run and from one run to the next.
#
# Stubbed are only RunningSushi::Log (Syslog), at_exit (the handlers would
# pile up in the RSpec process) and the postrun hook, as a spy on the
# outcome a plugin sees.

require_relative 'integration_helper'

# $success and $status_msg carry main's outcome to the at_exit handler, and
# $lockfileh holds the lock; main sets all three.
# rubocop:disable-next Style/GlobalVars
describe 'main' do
  let(:tmpdir) { Dir.mktmpdir }
  let(:upstream) { File.join(tmpdir, 'upstream') }
  let(:flags) { [] }
  let!(:head) do
    git(tmpdir, 'init', '-q', 'upstream')
    add_fixtures(upstream, %w[roles/test-role.json environments/test-env.json])
    commit_all(upstream)
  end
  # Everything a run writes stays under tmpdir; the Chef settings point at
  # ChefZero.
  let(:config) do
    { master_path: File.join(tmpdir, 'work'), repo_url: upstream, lockfile: File.join(tmpdir, 'lock'),
      pidfile: pidfile, plugin_path: File.join(tmpdir, 'no-plugin.rb'), chef_server_url: CHEF_ZERO_SERVER.url,
      pem: CHEF_ZERO_KEY_FILE.path, ssl_verify_mode: :verify_none }
  end

  def pidfile
    File.join(tmpdir, 'pid')
  end

  # Writes +config+ as a running-sushi config file and returns its path.
  def config_file
    File.join(tmpdir, 'config.rb').tap do |path|
      File.write(path, config.map { |key, value| "#{key} #{value.inspect}\n" }.join)
    end
  end

  # A complete run without flags, as an earlier cron run would have done.
  # Its process would have exited, releasing the lock: the next main in this
  # process would otherwise block forever on its own flock. Each run reads
  # ARGV afresh, and OptionParser#parse! consumes it.
  def earlier_run
    stub_const('ARGV', ['-c', config_file])
    main
    $lockfileh.close
    stub_const('ARGV', ['-c', config_file] + flags)
  end

  def edit_upstream_role(description)
    File.write(File.join(upstream, 'roles/test-role.json'), JSON.generate(name: 'test-role', description: description))
    commit_all(upstream)
  end

  def role_description
    Chef::Role.load('test-role').description
  end

  around do |example|
    saved = [$success, $status_msg, $lockfileh]
    example.run
  ensure
    $lockfileh&.close
    $success, $status_msg, $lockfileh = saved
  end

  before do
    $success = false
    $status_msg = 'NO WORK DONE'
    stub_const('ARGV', ['-c', config_file] + flags)
    allow(self).to receive(:at_exit)
    allow(RunningSushi::Hooks).to receive(:postrun)
    %i[warn info debug error].each { |level| allow(RunningSushi::Log).to receive(level) }
  end

  after { FileUtils.remove_entry(tmpdir) }

  context 'without a checkout' do
    it 'clones the repo and uploads it' do
      main
      expect([Chef::Role.list.keys, Chef::Environment.list.keys]).to eq([['test-role'], %w[_default test-env]])
    end

    it 'writes the checkpoint' do
      main
      expect(read_checkpoint).to eq(head)
    end

    it 'reports success to the postrun hook' do
      main
      expect(RunningSushi::Hooks).to have_received(:postrun).with(false, true, "Success at #{head}")
    end

    it 'removes its pidfile' do
      main
      expect(File).not_to exist(pidfile)
    end
  end

  context 'without a checkout or repo URL' do
    let(:config) { super().merge(repo_url: nil) }

    it 'exits 1' do
      expect { main }.to exit_with(1)
    end
  end

  context 'with a checkout from an earlier run' do
    before { earlier_run }

    it 'applies new upstream commits' do
      edit_upstream_role('edited')
      main
      expect(role_description).to eq('edited')
    end

    it 'moves the checkpoint to the new head' do
      new_head = edit_upstream_role('edited')
      main
      expect(read_checkpoint).to eq(new_head)
    end

    it 'reports success without new commits' do
      main
      expect(RunningSushi::Hooks).to have_received(:postrun).with(false, true, "Success at #{head}").twice
    end
  end

  context 'with -n and a checkout from an earlier run' do
    let(:flags) { ['-n'] }

    before do
      earlier_run
      edit_upstream_role('edited')
    end

    it 'applies nothing' do
      expect { main }.not_to(change { [role_description, read_checkpoint] })
    end
  end

  context 'with -n and no checkout' do
    let(:flags) { ['-n'] }

    it 'exits without touching the server', :aggregate_failures do
      expect { main }.to exit_with(0)
      expect(Chef::Role.list).to be_empty
    end
  end

  # A failed run must leave the checkpoint alone, so the next run retries
  # the same diff once the file is fixed.
  context 'with a file that contradicts its path' do
    before do
      add_fixtures(upstream, ['roles/misnamed-role.json'])
      commit_all(upstream)
    end

    it 'reports the failure to the postrun hook' do
      main
      expect(RunningSushi::Hooks).to have_received(:postrun).with(false, false, %r{roles/misnamed-role\.json})
    end

    it 'writes no checkpoint' do
      main
      expect(read_checkpoint).to be_nil
    end
  end

  context 'with -r' do
    let(:flags) { ['-r'] }

    before { CHEF_ZERO_SERVER.load_data('roles' => { 'stray-role' => { 'name' => 'stray-role' } }) }

    it 'deletes roles that are not in Git' do
      main
      expect(Chef::Role.list.keys).to eq(['test-role'])
    end

    # After a failed diff step the server is mid-apply; reconcile must not
    # "fix" it towards a half-applied Git state. Two guards stop it here:
    # main's $success check, and reconcile's own refusal while HEAD is past
    # the checkpoint the failed run left behind. Either alone passes this.
    # The failing file is a node because reconcile only reads cookbooks and
    # roles: a misnamed role would make reconcile fail on its own, and this
    # would pass with both guards gone.
    context 'when the diff step fails' do
      before do
        add_fixtures(upstream, ['nodes/misnamed-node.json'])
        commit_all(upstream)
      end

      it 'skips the reconcile' do
        main
        expect(Chef::Role.list.keys).to eq(['stray-role'])
      end
    end
  end
end
