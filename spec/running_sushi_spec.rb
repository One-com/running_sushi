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

# Tests for bin/running-sushi
#
# Scope:
#   * ChangeProxy            - tiny value object used to fake a changeset entry
#   * checkpoint_path        - pure path derivation from RunningSushi::Config
#   * node_checkpoint_path   - pure path derivation from RunningSushi::Config
#   * pod_config             - chooses pod-specific dirs based on Config.pod_name
#
# The script `bin/running-sushi` is `load`-ed via a singleton-method stub for
# `main`, so loading it simply defines `ChangeProxy` and the helper methods
# without performing any work, talking to Chef, touching the file system or
# grabbing a lock.

require_relative 'spec_helper'

# Pull `bin/running-sushi` into the test process so its helper methods and
# the ChangeProxy class are defined, without triggering the real entry-point
# logic (config parsing, lockfile, repo clone, Chef uploads).
#
# The bin file defines `main` as an ordinary instance method on Object and
# then calls it unconditionally. We plant a no-op singleton method named
# `main` on the top-level `main` object *before* the load so that Ruby's
# method lookup — singleton class first, Object instance methods second —
# finds our stub instead of the real implementation when `main` is invoked
# at the bottom of the loaded file.
describe ChangeProxy do
  it 'stores the full_name passed to the constructor' do
    proxy = ChangeProxy.new('servers/host.example.com')
    expect(proxy.full_name).to eq('servers/host.example.com')
  end

  it 'stringifies to its full_name' do
    proxy = ChangeProxy.new('servers/host.example.com')
    expect(proxy.to_s).to eq('servers/host.example.com')
    expect("uploading #{proxy}").to eq('uploading servers/host.example.com')
  end

  it 'exposes full_name as a writable attribute' do
    proxy = ChangeProxy.new('one')
    proxy.full_name = 'two'
    expect(proxy.full_name).to eq('two')
    expect(proxy.to_s).to eq('two')
  end
end

describe 'config-derived path helpers' do
  before do
    # Preserve the config so other tests aren't affected by our tweaks.
    @original_config = RunningSushi::Config.save
  end

  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@original_config) if @original_config
  end

  describe 'checkpoint_path' do
    it 'joins master_path with rev_checkpoint' do
      RunningSushi::Config.master_path = '/var/chef/work'
      RunningSushi::Config.rev_checkpoint = 'rev'
      expect(checkpoint_path).to eq('/var/chef/work/rev')
    end
  end

  describe 'node_checkpoint_path' do
    it 'joins master_path with node_checkpoint' do
      RunningSushi::Config.master_path = '/var/chef/work'
      RunningSushi::Config.node_checkpoint = 'nodes.json'
      expect(node_checkpoint_path).to eq('/var/chef/work/nodes.json')
    end
  end

  describe 'pod_config' do
    it 'returns the configured dirs unchanged when no pod_name is set' do
      RunningSushi::Config.pod_name = nil
      RunningSushi::Config.node_path = 'nodes'
      RunningSushi::Config.client_path = 'clients'
      RunningSushi::Config.environment_path = 'environments'
      RunningSushi::Config.role_local_path = 'roles_local'

      node_dir, client_dir, environment_dir, role_local_dir = pod_config

      expect(node_dir).to eq('nodes')
      expect(client_dir).to eq('clients')
      expect(environment_dir).to eq('environments')
      expect(role_local_dir).to eq('roles_local')
    end

    it 'appends pod_name to each of the pod-scoped dirs' do
      RunningSushi::Config.pod_name = 'pod1'
      RunningSushi::Config.node_path = 'nodes'
      RunningSushi::Config.client_path = 'clients'
      RunningSushi::Config.environment_path = 'environments'
      RunningSushi::Config.role_local_path = 'roles_local'

      node_dir, client_dir, environment_dir, role_local_dir = pod_config

      expect(node_dir).to eq('nodes/pod1')
      expect(client_dir).to eq('clients/pod1')
      expect(environment_dir).to eq('environments/pod1')
      expect(role_local_dir).to eq('roles_local/pod1')
    end

    it 'stringifies non-string pod names (e.g. symbols) before joining' do
      RunningSushi::Config.pod_name = :pod2
      RunningSushi::Config.node_path = 'nodes'
      RunningSushi::Config.client_path = 'clients'
      RunningSushi::Config.environment_path = 'environments'
      RunningSushi::Config.role_local_path = 'roles_local'

      node_dir, client_dir, environment_dir, role_local_dir = pod_config

      expect(node_dir).to eq('nodes/pod2')
      expect(client_dir).to eq('clients/pod2')
      expect(environment_dir).to eq('environments/pod2')
      expect(role_local_dir).to eq('roles_local/pod2')
    end
  end
end

# ── Checkpoint I/O ────────────────────────────────────────────────────────────
#
# write_checkpoint / read_checkpoint and write_node_checkpoint /
# read_node_checkpoint are the core state-tracking mechanism: they persist
# the last-known Git revision (and which nodes were in-flight) to disk so
# that successive runs only process the delta.  Each test uses a private
# tmpdir as the master_path so no real filesystem state leaks between examples.

describe 'checkpoint I/O' do
  before do
    @orig_config = RunningSushi::Config.save
    @tmpdir = Dir.mktmpdir
    RunningSushi::Config.master_path    = @tmpdir
    RunningSushi::Config.rev_checkpoint = 'checkpoint'
    RunningSushi::Config.node_checkpoint = 'node_checkpoint.json'
    RunningSushi::Config.dry_run = false
  end

  after do
    FileUtils.remove_entry(@tmpdir)
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  describe 'write_checkpoint / read_checkpoint' do
    it 'round-trips a revision string' do
      write_checkpoint('abc123')
      expect(read_checkpoint).to eq('abc123')
    end

    it 'returns nil when no checkpoint file exists yet' do
      expect(read_checkpoint).to be_nil
    end

    it 'strips trailing whitespace on read' do
      File.write(checkpoint_path, "abc123\n")
      expect(read_checkpoint).to eq('abc123')
    end

    it 'overwrites an existing checkpoint with the new revision' do
      write_checkpoint('first')
      write_checkpoint('second')
      expect(read_checkpoint).to eq('second')
    end

    it 'skips writing when dry_run is true' do
      RunningSushi::Config.dry_run = true
      write_checkpoint('abc123')
      expect(File.exist?(checkpoint_path)).to be false
    end
  end

  describe 'write_node_checkpoint / read_node_checkpoint' do
    it 'round-trips a revision and a node list' do
      write_node_checkpoint(%w[web01 web02], 'sha1')
      checkpoint, nodes = read_node_checkpoint
      expect(checkpoint).to eq('sha1')
      expect(nodes).to eq(%w[web01 web02])
    end

    it 'returns nil and an empty array when no file exists' do
      checkpoint, nodes = read_node_checkpoint
      expect(checkpoint).to be_nil
      expect(nodes).to eq([])
    end

    it 'preserves an empty node list' do
      write_node_checkpoint([], 'sha1')
      checkpoint, nodes = read_node_checkpoint
      expect(checkpoint).to eq('sha1')
      expect(nodes).to eq([])
    end

    it 'overwrites a previous node checkpoint' do
      write_node_checkpoint(['web01'], 'old')
      write_node_checkpoint(%w[db01 db02], 'new')
      checkpoint, nodes = read_node_checkpoint
      expect(checkpoint).to eq('new')
      expect(nodes).to eq(%w[db01 db02])
    end

    it 'skips writing when dry_run is true' do
      RunningSushi::Config.dry_run = true
      write_node_checkpoint(['web01'], 'sha1')
      expect(File.exist?(node_checkpoint_path)).to be false
    end
  end
end

# ── action helper ─────────────────────────────────────────────────────────────
#
# action() is a one-liner wrapper that routes its message through Log.warn,
# but prepends "[DRYRUN] Would do:" when dry_run mode is active.  We stub
# Log.warn to capture the call without touching Syslog.

describe 'action' do
  before do
    @orig_config = RunningSushi::Config.save
  end

  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  it 'forwards the message to Log.warn as-is when dry_run is false' do
    RunningSushi::Config.dry_run = false
    expect(RunningSushi::Log).to receive(:warn).with('Uploading role')
    action('Uploading role')
  end

  it 'prefixes with [DRYRUN] and the intent phrase when dry_run is true' do
    RunningSushi::Config.dry_run = true
    expect(RunningSushi::Log).to receive(:warn).with('[DRYRUN] Would do: Uploading role')
    action('Uploading role')
  end
end

# ── Pidfile helpers ───────────────────────────────────────────────────────────

describe 'pidfile helpers' do
  before do
    @orig_config = RunningSushi::Config.save
    @tmpdir = Dir.mktmpdir
    RunningSushi::Config.pidfile = File.join(@tmpdir, 'running_sushi.pid')
  end

  after do
    FileUtils.remove_entry(@tmpdir)
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  describe 'write_pidfile' do
    it 'writes the current process PID to Config.pidfile' do
      write_pidfile
      expect(File.read(RunningSushi::Config.pidfile)).to eq(Process.pid.to_s)
    end
  end

  describe 'delete_pidfile' do
    it 'deletes the file when it exists' do
      write_pidfile
      delete_pidfile
      expect(File.exist?(RunningSushi::Config.pidfile)).to be false
    end

    it 'does not raise when the pidfile is missing' do
      expect { delete_pidfile }.not_to raise_error
    end
  end
end

# ── acquire_lock ──────────────────────────────────────────────────────────────

# $lockfileh is the production global set by acquire_lock; the after-block must
# close it to release the OS file lock between examples.
# rubocop:disable Style/GlobalVars
describe 'acquire_lock' do
  before do
    @orig_config = RunningSushi::Config.save
    @tmpdir = Dir.mktmpdir
    RunningSushi::Config.lockfile = File.join(@tmpdir, 'test.lock')
    # Stub Log.warn so Syslog is never opened during this test.
    allow(RunningSushi::Log).to receive(:warn)
  end

  after do
    $lockfileh&.close
    $lockfileh = nil
    FileUtils.remove_entry(@tmpdir)
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  it 'opens and exclusively flocks the configured lockfile' do
    acquire_lock
    expect($lockfileh).to be_a(File)
    expect($lockfileh.path).to eq(RunningSushi::Config.lockfile)
  end
end
# rubocop:enable Style/GlobalVars

# ── fetch_repo ────────────────────────────────────────────────────────────────

describe 'fetch_repo' do
  before do
    @orig_config = RunningSushi::Config.save
    RunningSushi::Config.master_path = '/var/chef/work'
    RunningSushi::Config.reponame    = 'myrepo'
    RunningSushi::Config.vcs_type    = 'git'
    RunningSushi::Config.vcs_path    = nil
  end

  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  it 'returns the repo object produced by ChefDiff::Repo.get' do
    repo = double('repo')
    allow(ChefDiff::Repo).to receive(:get).and_return(repo)
    expect(fetch_repo).to be(repo)
  end

  it 'sets repo.bin when vcs_path is configured' do
    repo = double('repo')
    allow(ChefDiff::Repo).to receive(:get).and_return(repo)
    expect(repo).to receive(:bin=).with('/usr/local/bin/git')
    RunningSushi::Config.vcs_path = '/usr/local/bin/git'
    fetch_repo
  end

  it 'does not set repo.bin when vcs_path is nil' do
    repo = double('repo')
    allow(ChefDiff::Repo).to receive(:get).and_return(repo)
    expect(repo).not_to receive(:bin=)
    fetch_repo
  end
end

# ── chef_upload ───────────────────────────────────────────────────────────────
#
# chef_upload is the central dispatch function.  We stub ChefDiff::Changeset
# and the knife double so no network I/O or filesystem Chef state is required.

describe 'chef_upload' do
  # A knife double that silently accepts every upload/delete call.
  let(:knife) do
    dbl = double('knife')
    %i[cookbook_delete cookbook_upload
       role_delete role_local_delete role_upload role_local_upload
       databag_delete databag_upload
       node_delete node_upload
       environment_delete environment_upload
       client_delete client_upload].each do |m|
      allow(dbl).to receive(m)
    end
    allow(dbl).to receive(:verify_node_upload).and_return(true)
    dbl
  end

  # Build a changeset double where every component list is empty.
  def empty_changeset
    cs = double('changeset')
    %i[cookbooks roles roles_local databags nodes environments clients].each do |m|
      allow(cs).to receive(m).and_return([])
    end
    cs
  end

  before do
    @orig_config = RunningSushi::Config.save
    @tmpdir = Dir.mktmpdir
    RunningSushi::Config.master_path      = @tmpdir
    RunningSushi::Config.reponame         = 'ops'
    RunningSushi::Config.dry_run          = false
    RunningSushi::Config.pod_name         = nil
    RunningSushi::Config.node_path        = 'nodes'
    RunningSushi::Config.client_path      = 'clients'
    RunningSushi::Config.environment_path = 'environments'
    RunningSushi::Config.role_local_path  = 'roles_local'
    RunningSushi::Config.role_path        = 'roles'

    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    # Stub the checkpoint I/O so tests don't depend on real files.
    allow(self).to receive(:read_node_checkpoint).and_return([nil, []])
    allow(self).to receive(:write_node_checkpoint)
    allow(ChefDiff::Changeset).to receive(:new).and_return(empty_changeset)
  end

  after do
    FileUtils.remove_entry(@tmpdir)
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig_config)
  end

  it 'calls all knife upload/delete methods with empty arrays when nothing changed' do
    chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

    expect(knife).to have_received(:cookbook_delete).with([])
    expect(knife).to have_received(:cookbook_upload).with([])
    expect(knife).to have_received(:role_delete).with([])
    expect(knife).to have_received(:role_upload).with([])
    expect(knife).to have_received(:node_upload).with([], 'new_rev')
    expect(knife).to have_received(:environment_upload).with([])
    expect(knife).to have_received(:client_upload).with([])
  end

  it 'rejects a global role from upload when a local override file exists' do
    role_change = double('role_change',
                         status: :created, full_name: 'myrole', name: 'myrole')
    cs = empty_changeset
    allow(cs).to receive(:roles).and_return([role_change])
    allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

    # Create the local-override file so the global role is rejected.
    local_dir = File.join(@tmpdir, 'ops', 'roles_local')
    FileUtils.mkdir_p(local_dir)
    File.write(File.join(local_dir, 'myrole.json'), '{}')

    chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

    expect(knife).to have_received(:role_upload).with([])
  end

  it 'promotes the matching global role when a local role is deleted' do
    deleted_local = double('deleted_local',
                           status: :deleted, full_name: 'myrole', name: 'myrole')
    cs = empty_changeset
    allow(cs).to receive(:roles_local).and_return([deleted_local])
    allow(ChefDiff::Changeset).to receive(:new).and_return(cs)

    # Global role file exists → should be promoted via a ChangeProxy.
    global_dir = File.join(@tmpdir, 'ops', 'roles')
    FileUtils.mkdir_p(global_dir)
    File.write(File.join(global_dir, 'myrole.json'), '{}')

    uploaded_roles = nil
    allow(knife).to receive(:role_upload) { |roles| uploaded_roles = roles }

    chef_upload(knife, double('repo'), 'old_rev', 'new_rev')

    expect(uploaded_roles.map(&:full_name)).to include('myrole')
  end

  it 'logs an error and exits 2 when ChefDiff raises ReferenceError' do
    allow(ChefDiff::Changeset).to receive(:new)
      .and_raise(ChefDiff::Changeset::ReferenceError)

    expect { chef_upload(knife, double('repo'), 'bad_rev', 'new_rev') }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }

    expect(RunningSushi::Log).to have_received(:error).with(/Repo error/)
  end
end
