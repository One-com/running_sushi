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

# Tests for RunningSushi::Log
#
# Scope:
#   * verbosity= / level filtering  — debug and info are gated; warn/error/fatal
#                                     are unconditional.
#   * message prefixing             — each severity prepends a distinct label.
#   * syslog level mapping          — correct Syslog::LOG_* constant is passed.
#   * lazy initialisation           — Syslog.open is called on the first log
#                                     call and not again until reset.
#
# Syslog is stubbed throughout so no real syslog connection is opened and no
# system log entries are written during the test run.

require_relative 'spec_helper'
require 'running_sushi/logging'

describe RunningSushi::Log do
  before do
    # Class variables are shared across the entire Ruby process; reset them
    # before each example so tests remain independent.
    RunningSushi::Log.reset!

    # Prevent real syslog writes.
    allow(Syslog).to receive(:open)
    allow(Syslog).to receive(:log)
  end

  # ── verbosity= ──────────────────────────────────────────────────────────────

  describe '.verbosity=' do
    it 'stores the supplied level' do
      RunningSushi::Log.verbosity = Logger::DEBUG
      expect(RunningSushi::Log.level).to eq(Logger::DEBUG)
    end

    it 'stores INFO level' do
      RunningSushi::Log.verbosity = Logger::INFO
      expect(RunningSushi::Log.class_variable_get(:@@level)).to eq(Logger::INFO)
    end
  end

  # ── .debug ───────────────────────────────────────────────────────────────────

  describe '.debug' do
    it 'is silent when verbosity is WARN' do
      expect(Syslog).not_to receive(:log)
      RunningSushi::Log.debug('hello')
    end

    it 'is silent when verbosity is INFO' do
      RunningSushi::Log.verbosity = Logger::INFO
      expect(Syslog).not_to receive(:log)
      RunningSushi::Log.debug('hello')
    end

    it 'logs at Syslog::LOG_DEBUG when verbosity is DEBUG' do
      RunningSushi::Log.verbosity = Logger::DEBUG
      expect(Syslog).to receive(:log).with(Syslog::LOG_DEBUG, '%s', anything)
      RunningSushi::Log.debug('hello')
    end

    it 'prepends DEBUG: to the message' do
      RunningSushi::Log.verbosity = Logger::DEBUG
      expect(Syslog).to receive(:log).with(Syslog::LOG_DEBUG, '%s', /\ADEBUG: /)
      RunningSushi::Log.debug('hello')
    end
  end

  # ── .info ────────────────────────────────────────────────────────────────────

  describe '.info' do
    it 'is silent when verbosity is WARN' do
      expect(Syslog).not_to receive(:log)
      RunningSushi::Log.info('hello')
    end

    it 'logs at Syslog::LOG_INFO when verbosity is INFO' do
      RunningSushi::Log.verbosity = Logger::INFO
      expect(Syslog).to receive(:log).with(Syslog::LOG_INFO, '%s', anything)
      RunningSushi::Log.info('hello')
    end

    it 'also logs when verbosity is DEBUG' do
      RunningSushi::Log.verbosity = Logger::DEBUG
      expect(Syslog).to receive(:log).with(Syslog::LOG_INFO, '%s', anything)
      RunningSushi::Log.info('hello')
    end

    it 'prepends INFO: to the message' do
      RunningSushi::Log.verbosity = Logger::INFO
      expect(Syslog).to receive(:log).with(Syslog::LOG_INFO, '%s', /\AINFO: /)
      RunningSushi::Log.info('hello')
    end
  end

  # ── .warn ────────────────────────────────────────────────────────────────────

  describe '.warn' do
    it 'always logs even when verbosity is above WARN' do
      RunningSushi::Log.verbosity = Logger::FATAL
      expect(Syslog).to receive(:log).with(Syslog::LOG_WARNING, '%s', anything)
      RunningSushi::Log.warn('hello')
    end

    it 'uses Syslog::LOG_WARNING' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_WARNING, anything, anything)
      RunningSushi::Log.warn('hello')
    end

    it 'prepends WARN: to the message' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_WARNING, '%s', /\AWARN: /)
      RunningSushi::Log.warn('hello')
    end
  end

  # ── .error ───────────────────────────────────────────────────────────────────

  describe '.error' do
    it 'always logs at Syslog::LOG_ERR' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_ERR, '%s', anything)
      RunningSushi::Log.error('hello')
    end

    it 'prepends ERROR: to the message' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_ERR, '%s', /\AERROR: /)
      RunningSushi::Log.error('hello')
    end
  end

  # ── .fatal ───────────────────────────────────────────────────────────────────

  describe '.fatal' do
    it 'always logs at Syslog::LOG_CRIT' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_CRIT, '%s', anything)
      RunningSushi::Log.fatal('hello')
    end

    it 'prepends CRITICAL: to the message' do
      expect(Syslog).to receive(:log).with(Syslog::LOG_CRIT, '%s', /\ACRITICAL: /)
      RunningSushi::Log.fatal('hello')
    end
  end

  # ── lazy initialisation ───────────────────────────────────────────────────────

  describe 'lazy Syslog initialisation' do
    it 'opens Syslog on the very first log call' do
      expect(Syslog).to receive(:open).once
      RunningSushi::Log.warn('first call')
    end

    it 'does not reopen Syslog on subsequent calls' do
      RunningSushi::Log.warn('first call') # triggers init
      expect(Syslog).not_to receive(:open)
      RunningSushi::Log.warn('second call')
    end
  end

  # ── stdout TTY branch ─────────────────────────────────────────────────────────
  #
  # `logit` calls `puts msg if $stdout.tty?`.  In a normal test run stdout is a
  # pipe (non-TTY), so the `then` branch is never hit.  Stubbing tty? forces it.

  describe 'stdout TTY branch' do
    it 'prints to stdout when stdout is a TTY' do
      allow($stdout).to receive(:tty?).and_return(true)
      expect($stdout).to receive(:puts).with(/WARN: /)
      RunningSushi::Log.warn('tty message')
    end
  end
end
