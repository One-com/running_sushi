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

# action() routes its message through Log.warn, but prepends
# "[DRYRUN] Would do:" when dry_run mode is active. Log.warn is stubbed to
# capture the call without touching Syslog.
describe 'action' do
  before { allow(RunningSushi::Log).to receive(:warn) }

  context 'without dry-run' do
    before { RunningSushi::Config.dry_run = false }

    it 'logs the message as is' do
      action('Uploading role')
      expect(RunningSushi::Log).to have_received(:warn).with('Uploading role')
    end
  end

  context 'when in dry-run mode' do
    before { RunningSushi::Config.dry_run = true }

    it 'logs what it would do' do
      action('Uploading role')
      expect(RunningSushi::Log).to have_received(:warn).with('[DRYRUN] Would do: Uploading role')
    end
  end
end
