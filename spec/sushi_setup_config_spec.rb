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

# setup_config parses ARGV, loads the config file and copies the Chef
# settings into Chef::Config. Config.from_file is stubbed, so the settings
# under test are set on RunningSushi::Config directly; spec_helper restores
# both configs after every example.

require_relative 'spec_helper'
require 'tempfile'

describe 'setup_config' do
  let(:argv) { [] }

  before do
    stub_const('ARGV', argv)
    allow(RunningSushi::Log).to receive(:warn)
    allow(RunningSushi::Log).to receive(:error)
    allow(RunningSushi::Hooks).to receive(:get)
    allow(self).to receive(:at_exit)
    allow(RunningSushi::Config).to receive(:from_file)
  end

  context 'with a missing -c config file' do
    let(:argv) { ['-c', '/no/such/config.rb'] }

    # The exit is what stops the run, the log line is its only explanation;
    # they cannot be split without swallowing the exit in one of the examples.
    it 'logs it and exits 2', :aggregate_failures do
      expect { setup_config }.to exit_with(2)
      expect(RunningSushi::Log).to have_received(:error).with(/Config file .* not found/)
    end
  end

  context 'with an existing -c config file' do
    let(:config_file) { Tempfile.create(['cfg', '.rb']) }
    let(:argv) { ['-c', config_file.path] }

    after do
      config_file.close
      File.unlink(config_file.path)
    end

    it 'loads it' do
      setup_config
      expect(RunningSushi::Config).to have_received(:from_file).with(config_file.path)
    end
  end

  # Values unlike both the Config defaults and the ChefZero settings of the
  # integration specs, so an unwired key cannot pass by coincidence.
  context 'with Chef settings' do
    let(:chef_keys) { %i[node_name client_key chef_server_url ssl_verify_mode] }

    before do
      RunningSushi::Config.user = 'sushi-spec'
      RunningSushi::Config.pem = '/spec/sushi.pem'
      RunningSushi::Config.chef_server_url = 'https://chef.example.com'
      RunningSushi::Config.ssl_verify_mode = :verify_none
    end

    it 'copies them into Chef::Config' do
      setup_config
      expect(chef_keys.to_h { |k| [k, Chef::Config[k]] }).to eq(
        node_name: 'sushi-spec', client_key: '/spec/sushi.pem',
        chef_server_url: 'https://chef.example.com', ssl_verify_mode: :verify_none
      )
    end
  end

  context 'without an ssl_verify_mode' do
    before { RunningSushi::Config.ssl_verify_mode = nil }

    it 'verifies the peer' do
      setup_config
      expect(Chef::Config[:ssl_verify_mode]).to eq(:verify_peer)
    end
  end

  it 'loads the plugin file' do
    setup_config
    expect(RunningSushi::Hooks).to have_received(:get).with(RunningSushi::Config.plugin_path)
  end

  context 'with -v' do
    let(:argv) { ['-v'] }

    it 'logs at INFO level' do
      setup_config
      expect(RunningSushi::Log.level).to eq(Logger::INFO)
    end
  end

  context 'with -vv' do
    let(:argv) { ['-vv'] }

    it 'logs at DEBUG level' do
      setup_config
      expect(RunningSushi::Log.level).to eq(Logger::DEBUG)
    end
  end

  context 'with -l and -p' do
    let(:argv) { ['-l', '/spec/sushi.lock', '-p', '/spec/sushi.pid'] }

    it 'uses those lock and pid files' do
      setup_config
      expect([RunningSushi::Config.lockfile, RunningSushi::Config.pidfile]).to eq(%w[/spec/sushi.lock /spec/sushi.pid])
    end
  end

  %w[-r --reconcile].each do |flag|
    context "with #{flag}" do
      let(:argv) { [flag] }

      it 'enables reconcile' do
        setup_config
        expect(RunningSushi::Config.reconcile).to be true
      end
    end
  end

  # -r takes no TYPES, or it would read -rn as the type n.
  context 'with -rn' do
    let(:argv) { ['-rn'] }

    it 'enables reconcile and dryrun', :aggregate_failures do
      expect { setup_config }.not_to raise_error
      expect([RunningSushi::Config.reconcile, RunningSushi::Config.dry_run]).to eq([true, true])
    end
  end

  context 'with --reconcile=TYPES' do
    let(:argv) { ['--reconcile=cookbooks,nodes'] }

    it 'limits reconcile to them' do
      setup_config
      expect(RunningSushi::Config.reconcile).to eq(%i[cookbooks nodes])
    end
  end

  context 'with an unknown reconcile type' do
    let(:argv) { ['--reconcile=cookbooks,cookbook'] }

    it 'logs it and exits 2', :aggregate_failures do
      expect { setup_config }.to exit_with(2)
      expect(RunningSushi::Log).to have_received(:error).with(/Unknown reconcile types: cookbook;/)
    end
  end

  context 'with an unknown reconcile type in the config file' do
    before { RunningSushi::Config.reconcile = ['bogus'] }

    it 'exits 2' do
      expect { setup_config }.to exit_with(2)
    end
  end

  # An empty list would turn reconcile on and compare nothing, silently.
  ['--reconcile=', '--reconcile=,'].each do |arg|
    context "with #{arg}" do
      let(:argv) { [arg] }

      it 'logs it and exits 2', :aggregate_failures do
        expect { setup_config }.to exit_with(2)
        expect(RunningSushi::Log).to have_received(:error).with(/No reconcile types given/)
      end
    end
  end

  context 'with an empty reconcile list in the config file' do
    before { RunningSushi::Config.reconcile = [] }

    it 'exits 2' do
      expect { setup_config }.to exit_with(2)
    end
  end

  context 'with reconcile types as strings in the config file' do
    before { RunningSushi::Config.reconcile = %w[nodes clients] }

    it 'reconciles them', :aggregate_failures do
      expect { setup_config }.not_to raise_error
      expect(reconcile_types).to eq(%i[nodes clients])
    end
  end

  context 'with -n' do
    let(:argv) { ['-n'] }

    it 'announces dryrun mode' do
      setup_config
      expect(RunningSushi::Log).to have_received(:warn).with(/Dryrun mode activated/)
    end
  end

  # main sets $success and $status_msg after setup_config has registered the
  # handler, so the handler must read them at exit, not capture them early.
  # -n makes every expected argument differ from its default.
  # rubocop:disable-next Style/GlobalVars
  context 'with -n when the process exits' do
    let(:argv) { ['-n'] }
    let(:exit_handlers) { [] }

    around do |example|
      saved = [$success, $status_msg]
      example.run
    ensure
      $success, $status_msg = saved
    end

    before do
      allow(self).to receive(:at_exit) { |&handler| exit_handlers << handler }
      allow(RunningSushi::Hooks).to receive(:atexit)
    end

    it 'passes the final outcome to the atexit hook' do
      setup_config
      $success = true
      $status_msg = 'Success at rev1'
      exit_handlers.each(&:call)
      expect(RunningSushi::Hooks).to have_received(:atexit).with(true, true, 'Success at rev1')
    end
  end
end
