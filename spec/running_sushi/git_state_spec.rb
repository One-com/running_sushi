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

require_relative '../spec_helper'
require 'running_sushi/git_state'

describe RunningSushi::GitState do
  def item(id, kind: :roles, change: nil)
    described_class::Item.new(id: id, kind: kind, change: change)
  end

  describe '.sources' do
    subject(:sources) { described_class.sources(items) }

    let(:global) { item('web', kind: :roles) }
    let(:local) { item('web', kind: :roles_local) }

    context 'with the same role global and local' do
      let(:items) { [local, global] }

      it 'uploads the local one' do
        expect(sources).to eq('web' => local)
      end
    end
  end

  describe '.unique_names!' do
    subject(:unique) { described_class.unique_names!(items) }

    def file_item(full_name, kind: :roles)
      item(File.basename(full_name), kind: kind, change: Change.new(full_name, full_name))
    end

    context 'with a global and a local role of one name' do
      let(:items) { [file_item('web'), file_item('sub/web', kind: :roles_local)] }

      it { expect { unique }.not_to raise_error }
    end

    context 'with two global roles of one name' do
      let(:items) { [file_item('a/web'), file_item('b/web'), file_item('db')] }

      it 'names both files' do
        expect { unique }.to raise_error(described_class::DuplicateNameError,
                                         'roles: role web is defined by more than one file: a/web.json, b/web.json')
      end
    end

    context 'with two names clashing' do
      let(:items) { [file_item('a/web'), file_item('b/web'), file_item('a/db'), file_item('b/db')] }

      it { expect { unique }.to raise_error(described_class::DuplicateNameError, /role web .*\n.*role db /) }
    end

    context 'with two local roles of one name' do
      let(:items) { [file_item('web', kind: :roles_local), file_item('sub/web', kind: :roles_local)] }

      it { expect { unique }.to raise_error(described_class::DuplicateNameError, /\Aroles_local: role web /) }
    end

    context 'with two nodes of one name' do
      let(:items) { [file_item('a/web01', kind: :nodes), file_item('b/web01', kind: :nodes)] }

      it 'names both files' do
        expect { unique }.to raise_error(described_class::DuplicateNameError,
                                         'nodes: node web01 is defined by more than one file: ' \
                                         'a/web01.json, b/web01.json')
      end
    end

    context 'with a node and a client of one name' do
      let(:items) { [file_item('web01', kind: :nodes), file_item('web01', kind: :clients)] }

      it { expect { unique }.not_to raise_error }
    end
  end
end
