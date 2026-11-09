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

describe 'fetch_repo' do
  let(:repo) { instance_double(ChefDiff::Repo::Git, 'bin=': nil) }

  before do
    RunningSushi::Config.master_path = '/var/chef/work'
    RunningSushi::Config.reponame    = 'myrepo'
    RunningSushi::Config.vcs_type    = 'git'
    RunningSushi::Config.vcs_path    = nil
    allow(ChefDiff::Repo).to receive(:get).and_return(repo)
  end

  it 'returns the repo from ChefDiff::Repo.get' do
    expect(fetch_repo).to be(repo)
  end

  it 'opens the checkout under master_path' do
    fetch_repo
    expect(ChefDiff::Repo).to have_received(:get).with('git', '/var/chef/work/myrepo', RunningSushi::Log)
  end

  context 'with a vcs_path' do
    before { RunningSushi::Config.vcs_path = '/usr/local/bin/git' }

    it 'points the repo at that binary' do
      fetch_repo
      expect(repo).to have_received(:bin=).with('/usr/local/bin/git')
    end
  end

  context 'without a vcs_path' do
    it 'leaves the binary alone' do
      fetch_repo
      expect(repo).not_to have_received(:bin=)
    end
  end
end
