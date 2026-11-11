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

describe 'pidfile helpers' do
  let(:tmpdir) { Dir.mktmpdir }

  before { RunningSushi::Config.pidfile = File.join(tmpdir, 'running_sushi.pid') }
  after { FileUtils.remove_entry(tmpdir) }

  describe 'write_pidfile' do
    it 'writes the PID to Config.pidfile' do
      write_pidfile
      expect(File.read(RunningSushi::Config.pidfile)).to eq(Process.pid.to_s)
    end
  end

  describe 'delete_pidfile' do
    context 'with a pidfile' do
      before { write_pidfile }

      it 'deletes it' do
        delete_pidfile
        expect(File).not_to exist(RunningSushi::Config.pidfile)
      end
    end

    context 'without a pidfile' do
      it 'does not raise' do
        expect { delete_pidfile }.not_to raise_error
      end
    end
  end
end
