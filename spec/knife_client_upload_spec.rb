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
require 'running_sushi/knife'

describe RunningSushi::Knife do
  describe '#client_upload (error paths)' do
    let(:logger) { double('logger', info: nil, warn: nil) }
    let(:knife)  { RunningSushi::Knife.new(logger: logger, client_dir: '/repo/clients') }
    let(:client) do
      double('apiclient', name: nil, public_key: nil, admin: nil,
                          create: nil, destroy: nil)
    end

    before do
      allow(File).to receive(:read).and_return('{"name":"web01","public_key":"KEY"}')
      allow(Chef::ApiClientV1).to receive(:new).and_return(client)
      allow(knife).to receive(:update_permissions) # isolate
    end

    def resp(code)
      double('response', code: code)
    end

    it 'creates the client after a 404 on destroy (happy 404 path)' do
      allow(client).to receive(:destroy)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      expect(logger).to receive(:info).with(/did not exist, creating/)
      knife.client_upload([make_change('web01')])
      expect(client).to have_received(:create)
    end

    it 're-raises a non-404 error from destroy (line 112 error arm)' do
      allow(client).to receive(:destroy)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.client_upload([make_change('web01')]) }
        .to raise_error(Net::HTTPClientException)
    end

    it 'warns "Should not be here!" on a 404 during create (line 130)' do
      allow(client).to receive(:create)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      expect(logger).to receive(:warn).with(/Should not be here/)
      knife.client_upload([make_change('web01')])
    end

    it 're-raises a non-404 error from create (line 129 error arm)' do
      allow(client).to receive(:create)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.client_upload([make_change('web01')]) }
        .to raise_error(Net::HTTPClientException)
    end
  end
end
