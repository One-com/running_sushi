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

# Syslog is stubbed throughout so no real syslog connection is opened and no
# system log entries are written during the test run.

require_relative '../spec_helper'
require 'running_sushi/logging'

describe RunningSushi::Log do
  before do
    # Class variables are shared across the entire Ruby process; reset them
    # before each example so tests remain independent.
    described_class.reset!

    allow(Syslog).to receive(:open)
    allow(Syslog).to receive(:log)
    # logit also prints when stdout is a TTY; keep an interactive run quiet.
    allow($stdout).to receive(:tty?).and_return(false)
  end

  describe '.verbosity=' do
    it 'sets the level' do
      described_class.verbosity = Logger::INFO
      expect(described_class.level).to eq(Logger::INFO)
    end
  end

  describe '.debug' do
    context 'with verbosity WARN' do
      it 'logs nothing' do
        described_class.debug('hello')
        expect(Syslog).not_to have_received(:log)
      end
    end

    context 'with verbosity INFO' do
      before { described_class.verbosity = Logger::INFO }

      it 'logs nothing' do
        described_class.debug('hello')
        expect(Syslog).not_to have_received(:log)
      end
    end

    context 'with verbosity DEBUG' do
      before { described_class.verbosity = Logger::DEBUG }

      it 'logs at LOG_DEBUG with a DEBUG: prefix' do
        described_class.debug('hello')
        expect(Syslog).to have_received(:log).with(Syslog::LOG_DEBUG, '%s', 'DEBUG: hello')
      end
    end

    context 'with verbosity DEBUG and a block' do
      before { described_class.verbosity = Logger::DEBUG }

      it 'logs what the block returns' do
        described_class.debug { 'hello' }
        expect(Syslog).to have_received(:log).with(Syslog::LOG_DEBUG, '%s', 'DEBUG: hello')
      end
    end

    context 'with verbosity INFO and a block' do
      before { described_class.verbosity = Logger::INFO }

      it 'does not run the block' do
        expect { |probe| described_class.debug(&probe) }.not_to yield_control
      end
    end
  end

  describe '.debug?' do
    subject { described_class.debug? }

    context 'with verbosity INFO' do
      before { described_class.verbosity = Logger::INFO }

      it { is_expected.to be(false) }
    end

    context 'with verbosity DEBUG' do
      before { described_class.verbosity = Logger::DEBUG }

      it { is_expected.to be(true) }
    end
  end

  describe '.info' do
    context 'with verbosity WARN' do
      it 'logs nothing' do
        described_class.info('hello')
        expect(Syslog).not_to have_received(:log)
      end
    end

    context 'with verbosity INFO' do
      before { described_class.verbosity = Logger::INFO }

      it 'logs at LOG_INFO with an INFO: prefix' do
        described_class.info('hello')
        expect(Syslog).to have_received(:log).with(Syslog::LOG_INFO, '%s', 'INFO: hello')
      end
    end

    context 'with verbosity DEBUG' do
      before { described_class.verbosity = Logger::DEBUG }

      it 'logs too' do
        described_class.info('hello')
        expect(Syslog).to have_received(:log).with(Syslog::LOG_INFO, '%s', 'INFO: hello')
      end
    end

    context 'with verbosity INFO and a block' do
      before { described_class.verbosity = Logger::INFO }

      it 'logs what the block returns' do
        described_class.info { 'hello' }
        expect(Syslog).to have_received(:log).with(Syslog::LOG_INFO, '%s', 'INFO: hello')
      end
    end

    context 'with verbosity WARN and a block' do
      it 'does not run the block' do
        expect { |probe| described_class.info(&probe) }.not_to yield_control
      end
    end
  end

  describe '.info?' do
    subject { described_class.info? }

    context 'with verbosity WARN' do
      it { is_expected.to be(false) }
    end

    context 'with verbosity INFO' do
      before { described_class.verbosity = Logger::INFO }

      it { is_expected.to be(true) }
    end
  end

  describe '.warn' do
    it 'logs at LOG_WARNING with a WARN: prefix' do
      described_class.warn('hello')
      expect(Syslog).to have_received(:log).with(Syslog::LOG_WARNING, '%s', 'WARN: hello')
    end

    context 'with a block' do
      it 'logs what the block returns' do
        described_class.warn { 'hello' }
        expect(Syslog).to have_received(:log).with(Syslog::LOG_WARNING, '%s', 'WARN: hello')
      end
    end

    context 'with verbosity FATAL' do
      before { described_class.verbosity = Logger::FATAL }

      it 'still logs' do
        described_class.warn('hello')
        expect(Syslog).to have_received(:log).with(Syslog::LOG_WARNING, '%s', 'WARN: hello')
      end
    end
  end

  describe '.error' do
    it 'logs at LOG_ERR with an ERROR: prefix' do
      described_class.error('hello')
      expect(Syslog).to have_received(:log).with(Syslog::LOG_ERR, '%s', 'ERROR: hello')
    end

    context 'with a block' do
      it 'logs what the block returns' do
        described_class.error { 'hello' }
        expect(Syslog).to have_received(:log).with(Syslog::LOG_ERR, '%s', 'ERROR: hello')
      end
    end
  end

  describe '.fatal' do
    it 'logs at LOG_CRIT with a CRITICAL: prefix' do
      described_class.fatal('hello')
      expect(Syslog).to have_received(:log).with(Syslog::LOG_CRIT, '%s', 'CRITICAL: hello')
    end

    context 'with a block' do
      it 'logs what the block returns' do
        described_class.fatal { 'hello' }
        expect(Syslog).to have_received(:log).with(Syslog::LOG_CRIT, '%s', 'CRITICAL: hello')
      end
    end
  end

  describe '.logit' do
    subject(:log_it) { described_class.logit(Syslog::LOG_WARNING, '100% done') }

    # A message is never the format string: a '%' in it would make Syslog
    # expect more arguments.
    it 'passes the message as a %s argument' do
      log_it
      expect(Syslog).to have_received(:log).with(Syslog::LOG_WARNING, '%s', '100% done')
    end

    context 'when Syslog is not open yet' do
      it 'opens it' do
        log_it
        expect(Syslog).to have_received(:open).once
      end
    end

    context 'when Syslog is already open' do
      before { described_class.logit(Syslog::LOG_WARNING, 'first') }

      it 'does not reopen it' do
        log_it
        expect(Syslog).to have_received(:open).once
      end
    end

    context 'when stdout is a TTY' do
      before { allow($stdout).to receive_messages(tty?: true, puts: nil) }

      it 'also prints the message' do
        log_it
        expect($stdout).to have_received(:puts).with('100% done')
      end
    end

    context 'when stdout is not a TTY' do
      before { allow($stdout).to receive(:puts) }

      it 'prints nothing' do
        log_it
        expect($stdout).not_to have_received(:puts)
      end
    end
  end
end
