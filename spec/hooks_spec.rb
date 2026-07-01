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

# Tests for RunningSushi::Hooks
#
# Scope:
#   * Hooks.get — file-absent branch (no-op) and file-present branch (eval).
#
# No Chef server or syslog connection is required.

require_relative 'spec_helper'
require 'tempfile'
require 'running_sushi/hooks'

describe RunningSushi::Hooks do
  describe '.get' do
    it 'does nothing when the file does not exist' do
      expect { RunningSushi::Hooks.get('/non/existent/path.rb') }.not_to raise_error
    end

    it 'evaluates the file contents when the file exists' do
      # Use a sentinel method (not a constant) to avoid NameError on
      # re-runs and to avoid the "already initialized constant" warning.
      Tempfile.create(['hooks_test', '.rb']) do |f|
        f.write('def self.hooks_test_sentinel; :loaded; end')
        f.flush
        RunningSushi::Hooks.get(f.path)
        expect(RunningSushi::Hooks.hooks_test_sentinel).to eq(:loaded)
      end
    end
  end
end
