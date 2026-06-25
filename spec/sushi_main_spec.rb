# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop:2:tabstop=2

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

# $success, $status_msg, $lockfileh are script-level globals defined in
# bin/running-sushi.  Tests must reset them before each example and read them
# after to observe main's side-effects; there is no public API alternative.
# rubocop:disable Style/GlobalVars
describe 'main' do
  let(:repo) { double('repo') }

  before do
    @orig = RunningSushi::Config.save
    RunningSushi::Config.dry_run = false
    RunningSushi::Config.repo_url = nil
    RunningSushi::Config.lockfile = '/tmp/test.lock'
    RunningSushi::Config.pidfile = '/tmp/test.pid'
    RunningSushi::Config.master_path = '/tmp'
    RunningSushi::Config.rev_checkpoint = 'rev_checkpoint'
    RunningSushi::Config.node_checkpoint = 'node_checkpoint'
    RunningSushi::Config.reponame = 'repo'
    RunningSushi::Config.vcs_type = :git

    # Reset global variables
    $success = false
    $status_msg = 'NO WORK DONE'
    $lockfileh = nil

    # Stub all helper methods and hooks
    allow(self).to receive(:setup_config)
    allow(self).to receive(:acquire_lock)
    allow(self).to receive(:write_pidfile)
    allow(self).to receive(:delete_pidfile)
    allow(self).to receive(:fetch_repo).and_return(repo)
    allow(self).to receive(:upload_changed).and_return('newrev')
    allow(self).to receive(:write_checkpoint)
    allow(self).to receive(:read_checkpoint).and_return('oldrev')
    allow(self).to receive(:read_node_checkpoint).and_return([nil, []])
    allow(self).to receive(:action)

    %i[preflight_checks prerun post_repo_up postrun atexit].each do |m|
      allow(RunningSushi::Hooks).to receive(m)
    end

    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    allow(RunningSushi::Log).to receive(:debug)

    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:delete).and_return(1)
  end

  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig)
  end

  it 'updates an existing repo and uploads when the rev changed' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('newrev')

    main

    expect(self).to have_received(:write_checkpoint).with('newrev')
    expect($success).to be true
    expect($status_msg).to match(/Success at newrev/)
  end

  it 'does nothing when the repo is unchanged and no nodes are pending' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(self).not_to receive(:upload_changed)
    expect($success).to be true
    expect($status_msg).to match(/Success at oldrev/)
  end

  it 'clones the repo when it does not exist and a repo_url is set' do
    RunningSushi::Config.repo_url = 'git@example.com:ops.git'
    allow(repo).to receive(:exists?).and_return(false)
    allow(repo).to receive(:checkout)
    allow(repo).to receive(:head_rev).and_return('newrev')

    main

    expect(repo).to have_received(:checkout).with('git@example.com:ops.git')
    expect($success).to be true
  end

  it 'exits 1 when there is no checked-out repo and no repo_url' do
    allow(repo).to receive(:exists?).and_return(false)
    RunningSushi::Config.repo_url = nil

    expect { main }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it 'short-circuits in dryrun mode with no repo' do
    RunningSushi::Config.dry_run = true
    RunningSushi::Config.repo_url = 'git@example.com:ops.git'
    allow(repo).to receive(:exists?).and_return(false)
    allow(repo).to receive(:checkout)

    expect { main }.to raise_error(SystemExit)
    expect(RunningSushi::Hooks).to have_received(:postrun).with(true, true, 'dryrun mode')
  end

  it 'calls all hooks in the correct order' do
    call_order = []
    allow(self).to receive(:setup_config) { call_order << :setup_config }
    allow(RunningSushi::Hooks).to receive(:preflight_checks) { call_order << :preflight_checks }
    allow(self).to receive(:acquire_lock) { call_order << :acquire_lock }
    allow(self).to receive(:write_pidfile) { call_order << :write_pidfile }
    allow(self).to receive(:fetch_repo) do
      call_order << :fetch_repo
      repo
    end
    allow(RunningSushi::Hooks).to receive(:prerun) { call_order << :prerun }
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update) { call_order << :repo_update }
    allow(repo).to receive(:head_rev).and_return('oldrev')
    allow(RunningSushi::Hooks).to receive(:post_repo_up) { call_order << :post_repo_up }
    allow(RunningSushi::Hooks).to receive(:postrun) { call_order << :postrun }
    allow(self).to receive(:delete_pidfile) { call_order << :delete_pidfile }

    main

    expect(call_order).to eq(%i[
                               setup_config
                               preflight_checks
                               acquire_lock
                               write_pidfile
                               fetch_repo
                               prerun
                               repo_update
                               post_repo_up
                               postrun
                               delete_pidfile
                             ])
  end

  it 'does not update repo in dryrun mode when repo exists' do
    RunningSushi::Config.dry_run = true
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(repo).not_to have_received(:update)
  end

  it 'does not checkout repo in dryrun mode when repo does not exist' do
    RunningSushi::Config.dry_run = true
    RunningSushi::Config.repo_url = 'git@example.com:ops.git'
    allow(repo).to receive(:exists?).and_return(false)
    allow(repo).to receive(:checkout)

    expect { main }.to raise_error(SystemExit)
    expect(repo).not_to have_received(:checkout)
  end

  it 'calls upload_changed with repo and checkpoint when rev changed' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('newrev')

    main

    expect(self).to have_received(:upload_changed).with(repo, 'oldrev')
  end

  it 'catches exceptions from upload_changed and sets status message' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('newrev')
    error = StandardError.new('Upload failed')
    allow(self).to receive(:upload_changed).and_raise(error)

    main

    expect($success).to be false
    expect($status_msg).to eq('Upload failed')
  end

  it 'calls preflight_checks with dry_run flag' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(RunningSushi::Hooks).to have_received(:preflight_checks).with(false)
  end

  it 'calls prerun hook with dry_run flag' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(RunningSushi::Hooks).to have_received(:prerun).with(false)
  end

  it 'calls postrun hook with dry_run, success, and status_msg' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(RunningSushi::Hooks).to have_received(:postrun).with(false, true, /Success at oldrev/)
  end

  it 'reads and respects node checkpoint when deciding to upload' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')
    allow(self).to receive(:read_node_checkpoint).and_return(['oldrev', ['node1.json']])

    main

    expect(self).to have_received(:upload_changed).with(repo, 'oldrev')
  end

  it 'skips upload when rev unchanged and node checkpoint is empty' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')
    allow(self).to receive(:read_node_checkpoint).and_return([nil, []])

    main

    expect(self).not_to receive(:upload_changed)
  end

  it 'logs warning message to status_msg' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(RunningSushi::Log).to have_received(:warn).with(/Success at oldrev/)
  end

  it 'deletes pidfile at the end' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(self).to have_received(:delete_pidfile)
  end

  it 'calls post_repo_up hook after repo setup' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('oldrev')

    main

    expect(RunningSushi::Hooks).to have_received(:post_repo_up).with(false)
  end

  it 'handles checkpoint being nil when repo is new' do
    allow(repo).to receive(:exists?).and_return(true)
    allow(repo).to receive(:update)
    allow(repo).to receive(:head_rev).and_return('newrev')
    allow(self).to receive(:read_checkpoint).and_return(nil)

    main

    expect(self).to have_received(:upload_changed).with(repo, nil)
  end
end
# rubocop:enable Style/GlobalVars
