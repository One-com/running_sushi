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
require 'tempfile'
require 'running_sushi/hooks'

describe RunningSushi::Hooks do
  describe '.get' do
    context 'without a plugin file' do
      it 'loads nothing' do
        expect(described_class.get('/non/existent/path.rb')).to be_nil
      end
    end

    context 'with a plugin file' do
      # A sentinel method, not a constant: redefining it on a re-run is
      # silent, a constant would warn "already initialized".
      it 'evaluates it in the Hooks class' do
        Tempfile.create(['hooks_test', '.rb']) do |f|
          File.write(f.path, 'def self.hooks_test_sentinel; :loaded; end')
          described_class.get(f.path)
          expect(described_class.hooks_test_sentinel).to eq(:loaded)
        end
      end
    end
  end
end
