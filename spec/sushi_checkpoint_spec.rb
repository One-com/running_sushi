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

# The checkpoint files are the core state-tracking mechanism: they persist
# the last-known Git revision (and which nodes were in-flight) to disk so
# that successive runs only process the delta. Each example uses a private
# tmpdir as the master_path so no real filesystem state leaks between them.
describe 'checkpoint helpers' do
  let(:tmpdir) { Dir.mktmpdir }

  before do
    RunningSushi::Config.master_path    = tmpdir
    RunningSushi::Config.rev_checkpoint = 'checkpoint'
    RunningSushi::Config.node_checkpoint = 'node_checkpoint.json'
    RunningSushi::Config.dry_run = false
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe 'write_checkpoint' do
    it 'stores the revision for read_checkpoint' do
      write_checkpoint('abc123')
      expect(read_checkpoint).to eq('abc123')
    end

    context 'with an existing checkpoint' do
      before { write_checkpoint('first') }

      it 'replaces it' do
        write_checkpoint('second')
        expect(read_checkpoint).to eq('second')
      end
    end

    context 'when in dry-run mode' do
      before { RunningSushi::Config.dry_run = true }

      it 'writes nothing' do
        write_checkpoint('abc123')
        expect(File).not_to exist(checkpoint_path)
      end
    end
  end

  describe 'read_checkpoint' do
    subject { read_checkpoint }

    context 'without a checkpoint file' do
      it { is_expected.to be_nil }
    end

    context 'with a trailing newline' do
      before { File.write(checkpoint_path, "abc123\n") }

      it { is_expected.to eq('abc123') }
    end
  end

  describe 'write_node_checkpoint' do
    it 'stores the revision and nodes' do
      write_node_checkpoint(%w[web01 web02], 'sha1')
      expect(read_node_checkpoint).to eq(['sha1', %w[web01 web02]])
    end

    context 'with an existing node checkpoint' do
      before { write_node_checkpoint(['web01'], 'old') }

      it 'replaces it' do
        write_node_checkpoint(%w[db01 db02], 'new')
        expect(read_node_checkpoint).to eq(['new', %w[db01 db02]])
      end
    end

    context 'without nodes' do
      it 'keeps the empty list' do
        write_node_checkpoint([], 'sha1')
        expect(read_node_checkpoint).to eq(['sha1', []])
      end
    end

    context 'when in dry-run mode' do
      before { RunningSushi::Config.dry_run = true }

      it 'writes nothing' do
        write_node_checkpoint(['web01'], 'sha1')
        expect(File).not_to exist(node_checkpoint_path)
      end
    end
  end

  describe 'add_node_checkpoint' do
    context 'with nodes recorded for the same revision' do
      before { write_node_checkpoint(['web01'], 'sha1') }

      it 'keeps them' do
        add_node_checkpoint(['db01'], 'sha1')
        expect(read_node_checkpoint).to eq(['sha1', %w[web01 db01]])
      end
    end

    context 'with nodes recorded for an older revision' do
      before { write_node_checkpoint(['web01'], 'old') }

      it 'drops them' do
        add_node_checkpoint(['db01'], 'sha1')
        expect(read_node_checkpoint).to eq(['sha1', ['db01']])
      end
    end
  end

  describe 'read_node_checkpoint' do
    context 'without a node checkpoint file' do
      it 'returns no revision and no nodes' do
        expect(read_node_checkpoint).to eq([nil, []])
      end
    end
  end
end
