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

# $lockfileh is the production global set by acquire_lock; the after-block must
# close it to release the OS file lock between examples.
# rubocop:disable-next Style/GlobalVars
describe 'acquire_lock' do
  let(:tmpdir) { Dir.mktmpdir }

  before do
    RunningSushi::Config.lockfile = File.join(tmpdir, 'test.lock')
    # Stub Log.warn so Syslog is never opened during this test.
    allow(RunningSushi::Log).to receive(:warn)
  end

  after do
    $lockfileh&.close
    $lockfileh = nil
    FileUtils.remove_entry(tmpdir)
  end

  # flock locks belong to the open file description, so a second File.open in
  # this process competes for the lock like another run would.
  it 'locks out a second run' do
    acquire_lock
    File.open(RunningSushi::Config.lockfile) { |f| expect(f.flock(File::LOCK_EX | File::LOCK_NB)).to be(false) }
  end
end
