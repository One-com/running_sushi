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

describe 'update_repo' do
  let(:repo) { instance_double(ChefDiff::Repo::Git) }

  before { allow(RunningSushi::Log).to receive(:error) }

  context 'when the pull succeeds' do
    before { allow(repo).to receive(:update).and_return('Already up to date.') }

    it 'returns the pull output' do
      expect(update_repo(repo)).to eq('Already up to date.')
    end
  end

  context 'when the pull fails' do
    before { allow(repo).to receive(:update).and_raise(Mixlib::ShellOut::ShellCommandFailed, 'merge conflict') }

    it 're-raises the failure' do
      expect { update_repo(repo) }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
    end

    it 'logs the git output', :aggregate_failures do
      expect { update_repo(repo) }.to raise_error(Mixlib::ShellOut::ShellCommandFailed)
      expect(RunningSushi::Log).to have_received(:error).with('Updating the repo failed: merge conflict')
    end
  end
end
