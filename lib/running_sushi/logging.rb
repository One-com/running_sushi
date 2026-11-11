# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

# Copyright 2013-2014 Facebook
# Copyright 2017-present One.com
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

require 'syslog'
require 'logger'

module RunningSushi
  # Logging wrapper
  # @@init and @@level track module-level state; Log is a standalone namespace
  # never mixed into other classes, so the class-variable inheritance hazard
  # does not apply.
  # rubocop:disable-next Style/ClassVars
  module Log
    @@init = false
    @@level = Logger::WARN

    def self.init
      Syslog.open(File.basename($PROGRAM_NAME, '.rb'))
      @@init = true
    end

    def self.verbosity=(val)
      @@level = val
    end

    def self.level
      @@level
    end

    def self.reset!
      @@init = false
      @@level = Logger::WARN
    end

    def self.logit(level, msg)
      init unless @@init
      # You can't do `Syslog.log(level, msg)` because if there is a
      # `%` in `msg` then ruby will interpret it as a printf string and
      # expect more arguments to log().
      Syslog.log(level, '%s', msg)
      puts msg if $stdout.tty?
    end

    # The level methods follow ::Logger's calling convention, so Log can be
    # passed where a ::Logger is expected (ChefDiff::Changeset): each takes a
    # message or a block that builds it, and the block only runs when the
    # level is on. debug?/info? let callers skip work for levels that are off.
    def self.debug?
      @@level == Logger::DEBUG
    end

    def self.info?
      @@level <= Logger::INFO
    end

    def self.debug(msg = nil, &block)
      write(Syslog::LOG_DEBUG, 'DEBUG', msg, &block) if debug?
    end

    def self.info(msg = nil, &block)
      write(Syslog::LOG_INFO, 'INFO', msg, &block) if info?
    end

    def self.warn(msg = nil, &block)
      write(Syslog::LOG_WARNING, 'WARN', msg, &block)
    end

    def self.error(msg = nil, &block)
      write(Syslog::LOG_ERR, 'ERROR', msg, &block)
    end

    def self.fatal(msg = nil, &block)
      write(Syslog::LOG_CRIT, 'CRITICAL', msg, &block)
    end

    # Logs +msg+, or what the block returns when one is given, at the syslog
    # +priority+ with a "+label+: " prefix.
    def self.write(priority, label, msg)
      text = block_given? ? yield : msg
      logit(priority, "#{label}: #{text}")
    end
  end
end
