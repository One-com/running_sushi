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

# $success and $status_msg are script-level globals defined in
# bin/running-sushi.  Tests must reset them before each example and read them
# after to observe main's side-effects; there is no public API alternative.
# rubocop:disable-next Style/GlobalVars
describe 'main' do
  let(:repo) { instance_double(ChefDiff::Repo::Git, update: nil, checkout: nil) }

  # What main reports to the postrun hook.
  def outcome
    [$success, $status_msg]
  end

  before do
    $success = false
    $status_msg = 'NO WORK DONE'

    # Every helper that touches the file system, the lock or the repo is
    # stubbed, so main's own config reads are just dry_run and repo_url.
    allow(self).to receive_messages(
      setup_config: nil, acquire_lock: nil, write_pidfile: nil, delete_pidfile: nil, action: nil,
      fetch_repo: repo, read_checkpoint: 'oldrev', read_node_checkpoint: [nil, []],
      upload_changed: 'newrev', write_checkpoint: nil
    )

    %i[preflight_checks prerun post_repo_up postrun atexit].each do |m|
      allow(RunningSushi::Hooks).to receive(m)
    end

    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    allow(RunningSushi::Log).to receive(:debug)
  end

  context 'when the repo is unchanged and no nodes are pending' do
    before { allow(repo).to receive_messages(exists?: true, head_rev: 'oldrev') }

    it 'skips the upload' do
      main
      expect(self).not_to have_received(:upload_changed)
    end

    it 'reports success at the checkpoint' do
      main
      expect(outcome).to eq([true, 'Success at oldrev'])
    end

    it 'logs the status' do
      main
      expect(RunningSushi::Log).to have_received(:warn).with('Success at oldrev')
    end

    it 'passes the outcome to the postrun hook' do
      main
      expect(RunningSushi::Hooks).to have_received(:postrun).with(false, true, 'Success at oldrev')
    end

    %i[preflight_checks prerun post_repo_up].each do |hook|
      it "passes dry_run to the #{hook} hook" do
        main
        expect(RunningSushi::Hooks).to have_received(hook).with(false)
      end
    end

    it 'deletes the pidfile' do
      main
      expect(self).to have_received(:delete_pidfile)
    end

    context 'with every step recording its call' do
      let(:calls) { [] }
      let(:steps) do
        %i[setup_config preflight_checks acquire_lock write_pidfile fetch_repo
           prerun repo_update post_repo_up postrun delete_pidfile]
      end

      before do
        %i[setup_config acquire_lock write_pidfile delete_pidfile].each do |m|
          allow(self).to receive(m) { calls << m }
        end
        %i[preflight_checks prerun post_repo_up postrun].each do |m|
          allow(RunningSushi::Hooks).to receive(m) { calls << m }
        end
        allow(self).to receive(:fetch_repo) do
          calls << :fetch_repo
          repo
        end
        allow(repo).to receive(:update) { calls << :repo_update }
      end

      it 'runs the steps in order' do
        main
        expect(calls).to eq(steps)
      end
    end
  end

  context 'when the repo rev changed' do
    before { allow(repo).to receive_messages(exists?: true, head_rev: 'newrev') }

    it 'uploads from the stored checkpoint' do
      main
      expect(self).to have_received(:upload_changed).with(repo, 'oldrev')
    end

    it 'writes the new checkpoint' do
      main
      expect(self).to have_received(:write_checkpoint).with('newrev')
    end

    it 'reports success at the new rev' do
      main
      expect(outcome).to eq([true, 'Success at newrev'])
    end
  end

  context 'when nodes from the last upload are pending' do
    before do
      allow(repo).to receive_messages(exists?: true, head_rev: 'oldrev')
      allow(self).to receive(:read_node_checkpoint).and_return(['oldrev', ['node1.json']])
    end

    it 'uploads although the rev is unchanged' do
      main
      expect(self).to have_received(:upload_changed).with(repo, 'oldrev')
    end
  end

  context 'without a stored checkpoint' do
    before do
      allow(repo).to receive_messages(exists?: true, head_rev: 'newrev')
      allow(self).to receive(:read_checkpoint).and_return(nil)
    end

    it 'uploads from a nil checkpoint' do
      main
      expect(self).to have_received(:upload_changed).with(repo, nil)
    end
  end

  context 'when the upload raises' do
    before do
      allow(repo).to receive_messages(exists?: true, head_rev: 'newrev')
      allow(self).to receive(:upload_changed).and_raise(StandardError, 'Upload failed')
    end

    it 'reports the failure' do
      main
      expect(outcome).to eq([false, 'Upload failed'])
    end

    # The next run diffs from the checkpoint; advancing it past a failed
    # upload would drop those changes for good.
    it 'keeps the old checkpoint' do
      main
      expect(self).not_to have_received(:write_checkpoint)
    end
  end

  context 'when no repo is checked out' do
    before { allow(repo).to receive(:exists?).and_return(false) }

    context 'with a repo_url' do
      before { RunningSushi::Config.repo_url = 'git@example.com:ops.git' }

      it 'clones it' do
        main
        expect(repo).to have_received(:checkout).with('git@example.com:ops.git')
      end

      it 'reports success' do
        main
        expect(outcome).to eq([true, 'Success at newrev'])
      end
    end

    context 'without a repo_url' do
      it 'exits 1' do
        expect { main }.to exit_with(1)
      end
    end
  end

  # A dry run without a repo ends in Kernel#exit; what main did before the
  # exit can only be checked in the same example, hence :aggregate_failures.
  context 'when in dry-run mode' do
    before do
      RunningSushi::Config.dry_run = true
      RunningSushi::Config.repo_url = 'git@example.com:ops.git'
    end

    context 'with a checked-out repo' do
      before { allow(repo).to receive_messages(exists?: true, head_rev: 'oldrev') }

      it 'does not update it' do
        main
        expect(repo).not_to have_received(:update)
      end
    end

    context 'without a checked-out repo' do
      before { allow(repo).to receive(:exists?).and_return(false) }

      it 'exits without cloning', :aggregate_failures do
        expect { main }.to exit_with(0)
        expect(repo).not_to have_received(:checkout)
      end

      it 'reports dryrun mode, then exits', :aggregate_failures do
        expect { main }.to exit_with(0)
        expect(RunningSushi::Hooks).to have_received(:postrun).with(true, true, 'dryrun mode')
      end
    end
  end

  context 'with reconcile enabled' do
    before do
      RunningSushi::Config.reconcile = true
      allow(repo).to receive_messages(exists?: true, update: nil, head_rev: 'newrev')
      allow(self).to receive(:reconcile)
    end

    it 'reconciles the repo' do
      main
      expect(self).to have_received(:reconcile).with(repo)
    end

    context 'when the diff step fails' do
      before { allow(self).to receive(:upload_changed).and_raise(StandardError, 'Upload failed') }

      it 'does not reconcile' do
        main
        expect(self).not_to have_received(:reconcile)
      end
    end

    context 'when reconcile raises' do
      before { allow(self).to receive(:reconcile).and_raise(StandardError, 'server down') }

      it 'fails the run' do
        main
        expect([$success, $status_msg]).to eq([false, 'Reconcile failed: server down'])
      end
    end
  end

  context 'with reconcile disabled' do
    before do
      allow(repo).to receive_messages(exists?: true, update: nil, head_rev: 'newrev')
      allow(self).to receive(:reconcile)
    end

    it 'does not reconcile' do
      main
      expect(self).not_to have_received(:reconcile)
    end
  end
end
