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

# Tests for upload_changed helper method in bin/running-sushi

require_relative 'spec_helper'

describe 'upload_changed' do
  before do
    @orig = RunningSushi::Config.save
    RunningSushi::Config.master_path = '/var/chef/work'
    RunningSushi::Config.reponame = 'ops'
    RunningSushi::Config.pod_name = nil
    allow(RunningSushi::Log).to receive(:warn)
    allow(self).to receive(:chef_upload)
  end
  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig)
  end

  it 'builds a knife, delegates to chef_upload and returns the head rev' do
    repo = double('repo', head_rev: 'deadbeef')
    knife = double('knife')
    allow(RunningSushi::Knife).to receive(:new).and_return(knife)
    result = upload_changed(repo, 'old_rev')
    expect(RunningSushi::Knife).to have_received(:new)
    expect(self).to have_received(:chef_upload).with(knife, repo, 'old_rev', 'deadbeef')
    expect(result).to eq('deadbeef')
  end
end
