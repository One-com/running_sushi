# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop:2:tabstop=2

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
  describe '#update_permissions' do
    let(:logger) { double('logger', info: nil, warn: nil) }
    let(:knife)  { RunningSushi::Knife.new(logger: logger) }
    let(:api)    { double('api') }

    def acl(read_actors = [])
      {
        'read' => { 'actors' => read_actors },
        'update' => { 'actors' => [] },
        'delete' => { 'actors' => [] },
        'grant' => { 'actors' => [] }
      }
    end

    before do
      allow(Chef::Node).to receive(:list).and_return('web01' => 'uri')
      allow(knife).to receive(:http_api).and_return(api)
    end

    it 'returns early when the node is not in Chef::Node.list' do
      allow(Chef::Node).to receive(:list).and_return({})
      expect(knife).not_to receive(:http_api)
      knife.update_permissions('absent')
    end

    it 'appends the node to every perm and PUTs the updated ACL' do
      data = acl
      allow(api).to receive(:get_rest).with('nodes/web01/_acl').and_return(data)
      allow(api).to receive(:put_rest)
      knife.update_permissions('web01')
      expect(api).to have_received(:put_rest).exactly(4).times
      expect(data['read']['actors']).to include('web01')
    end

    it 'skips a perm the node already owns (the `next if` branch)' do
      allow(api).to receive(:get_rest).and_return(acl(['web01']))
      allow(api).to receive(:put_rest)
      knife.update_permissions('web01')
      expect(api).to have_received(:put_rest).exactly(3).times
    end

    it 'warns when a PUT fails' do
      resp = double('response', code: '500')
      allow(api).to receive(:get_rest).and_return(acl)
      allow(api).to receive(:put_rest)
        .and_raise(Net::HTTPClientException.new('boom', resp))
      expect(logger).to receive(:warn).with(/Failed to set permission/).at_least(:once)
      knife.update_permissions('web01')
    end

    it 'logs and returns when the GET raises (chef 11 has no ACL endpoint)' do
      resp = double('response', code: '405')
      allow(api).to receive(:get_rest)
        .and_raise(Net::HTTPClientException.new('no acl', resp))
      expect(logger).to receive(:info).with(/ACL probably not supported/)
      expect(api).not_to receive(:put_rest)
      knife.update_permissions('web01')
    end
  end
end
