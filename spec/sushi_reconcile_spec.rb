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

# Tests for the reconcile helper method in bin/running-sushi

require_relative 'spec_helper'

describe 'reconcile' do
  let(:repo) { instance_double(ChefDiff::Repo::Git, head_rev: 'rev1') }
  let(:changeset) { instance_double(ChefDiff::Changeset) }
  let(:knife) { instance_double(RunningSushi::Knife) }
  let(:checks) { [instance_double(RunningSushi::Reconcile::Check)] }

  before do
    allow(self).to receive_messages(checkout_knife: knife, changeset_locations: { role_dir: 'roles' })
    allow(ChefDiff::Changeset).to receive(:new).and_return(changeset)
    allow(RunningSushi::Reconcile).to receive(:compare).and_return(checks)
    allow(RunningSushi::Reconcile).to receive(:apply)
    allow(RunningSushi::Log).to receive(:warn)
    RunningSushi::Config.reconcile = true
  end

  context 'when HEAD is at the checkpoint' do
    before { allow(self).to receive(:read_checkpoint).and_return('rev1') }

    it 'lists every file in Git' do
      reconcile(repo)
      expect(ChefDiff::Changeset).to have_received(:new).with(RunningSushi::Log, repo, nil, nil, { role_dir: 'roles' })
    end

    it 'compares every type' do
      reconcile(repo)
      expect(RunningSushi::Reconcile).to have_received(:compare)
        .with(any_args, hash_including(types: RunningSushi::Reconcile::TYPES.keys))
    end

    context 'with a list of types' do
      before { RunningSushi::Config.reconcile = %i[nodes cookbooks nodes] }

      it 'compares only those, once each' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare).with(any_args,
                                                                        hash_including(types: %i[nodes cookbooks]))
      end
    end

    context 'without a pod_name' do
      it 'compares global roles only' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare)
          .with(knife, changeset, RunningSushi::Log, { role_dir: 'roles' }, hash_including(local_roles: false))
      end
    end

    # pod_config treats false as no pod_name, so local roles must stay off.
    context 'with pod_name false' do
      before { RunningSushi::Config.pod_name = false }

      it 'compares global roles only' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare).with(any_args, hash_including(local_roles: false))
      end
    end

    context 'with a pod_name' do
      before { RunningSushi::Config.pod_name = 'pod1' }

      it 'compares local roles too' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare).with(any_args, hash_including(local_roles: true))
      end
    end

    it 'fixes the drift' do
      reconcile(repo)
      expect(RunningSushi::Reconcile).to have_received(:apply).with(knife, checks, 'rev1')
    end

    # Added to, not overwritten: nodes a diff run uploaded for the same
    # revision are still waiting for their verification.
    it 'records the uploaded nodes for verification' do
      allow(RunningSushi::Reconcile).to receive(:apply).and_yield(['nodes/web01.json'])
      allow(self).to receive(:add_node_checkpoint)
      reconcile(repo)
      expect(self).to have_received(:add_node_checkpoint).with(['nodes/web01.json'], 'rev1')
    end

    context 'with dry-run' do
      before { RunningSushi::Config.dry_run = true }

      it 'still compares' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare)
      end

      it 'changes nothing' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).not_to have_received(:apply)
      end
    end
  end

  context 'when HEAD is not applied yet' do
    before { allow(self).to receive(:read_checkpoint).and_return('rev0') }

    it 'does not compare' do
      reconcile(repo)
      expect(RunningSushi::Reconcile).not_to have_received(:compare)
    end

    it 'says why' do
      reconcile(repo)
      expect(RunningSushi::Log).to have_received(:warn)
        .with('Reconcile: skipped, HEAD rev1 is not applied yet (checkpoint rev0)')
    end

    context 'with dry-run' do
      before { RunningSushi::Config.dry_run = true }

      it 'still compares' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).to have_received(:compare)
      end

      it 'warns that the commits count as drift' do
        reconcile(repo)
        expect(RunningSushi::Log).to have_received(:warn)
          .with(/HEAD rev1 is not applied yet \(checkpoint rev0\), so the report counts its unapplied commits/)
      end

      it 'changes nothing' do
        reconcile(repo)
        expect(RunningSushi::Reconcile).not_to have_received(:apply)
      end
    end
  end

  # Only a dry run can get here without a checkpoint: a real run writes it
  # just before reconcile.
  context 'with dry-run and no checkpoint' do
    before do
      RunningSushi::Config.dry_run = true
      allow(self).to receive(:read_checkpoint).and_return(nil)
    end

    it 'still compares' do
      reconcile(repo)
      expect(RunningSushi::Reconcile).to have_received(:compare)
    end

    it 'says there is none' do
      reconcile(repo)
      expect(RunningSushi::Log).to have_received(:warn)
        .with(/HEAD rev1 is not applied yet \(no checkpoint yet\), so the report counts/)
    end
  end
end
