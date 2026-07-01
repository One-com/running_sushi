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

# Tests for setup_config helper method in bin/running-sushi

require_relative 'spec_helper'
require 'tempfile'

describe 'setup_config' do
  before do
    @orig = RunningSushi::Config.save
    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    allow(RunningSushi::Hooks).to receive(:get)
    allow(self).to receive(:at_exit)
    allow(RunningSushi::Config).to receive(:from_file)
  end
  after do
    RunningSushi::Config.reset
    RunningSushi::Config.restore(@orig)
  end

  it 'exits 2 when a -c config file does not exist' do
    stub_const('ARGV', ['-c', '/no/such/config.rb'])
    expect { setup_config }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
    expect(RunningSushi::Log).to have_received(:error).with(/Config file .* not found/)
  end

  it 'loads an existing config file and wires Chef::Config' do
    Tempfile.create(['cfg', '.rb']) do |f|
      stub_const('ARGV', ['-c', f.path])
      setup_config
      expect(RunningSushi::Config).to have_received(:from_file).with(f.path)
      expect(Chef::Config[:node_name]).to eq(RunningSushi::Config.user)
    end
  end

  it 'sets DEBUG verbosity when -v is given twice' do
    stub_const('ARGV', ['-vv'])
    setup_config
    expect(RunningSushi::Config.verbosity).to eq(Logger::DEBUG)
  end

  it 'announces dryrun mode when -n is given' do
    stub_const('ARGV', ['-n'])
    expect(RunningSushi::Log).to receive(:warn).with(/Dryrun mode activated/)
    setup_config
  end
end
