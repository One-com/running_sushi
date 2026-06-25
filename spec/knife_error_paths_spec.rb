# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth:2:softtabstop:2:tabstop:2

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
  let(:logger) { double('logger', info: nil) }
  let(:knife)  { RunningSushi::Knife.new(logger: logger, databag_dir: '/repo/data_bags') }
  def resp(code)
    double('response', code: code)
  end

  describe '#delete_standard' do
    it 're-raises when the error is not a 404 (line 196)' do
      comp = double('component', name: 'web01')
      allow(Chef::Role).to receive(:load)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.delete_standard('roles', [comp], Chef::Role) }
        .to raise_error(Net::HTTPClientException)
    end

    it 'logs "not found" and swallows a 404 (line 196 false arm)' do
      comp = double('component', name: 'web01')
      allow(Chef::Role).to receive(:load)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      expect(logger).to receive(:info).with(/not found. Cannot delete/)
      expect { knife.delete_standard('roles', [comp], Chef::Role) }
        .not_to raise_error
    end
  end

  describe '#create_databag_if_missing' do
    it 're-raises when the load error is not a 404 (line 228)' do
      allow(Chef::DataBag).to receive(:load)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.create_databag_if_missing('mybag') }
        .to raise_error(Net::HTTPClientException)
    end
  end

  describe '#databag_delete' do
    it 're-raises when deleting an item fails with non-404 (line 245)' do
      allow(Chef::DataBagItem).to receive(:load)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.databag_delete([databag_change('mybag', 'item1')]) }
        .to raise_error(Net::HTTPClientException)
    end

    it 'logs "not found" and swallows a 404 on item delete (line 245 false arm)' do
      allow(Chef::DataBagItem).to receive(:load)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      allow(knife).to receive(:delete_databag_if_empty)
      expect(logger).to receive(:info).with(/not found. Cannot delete/)
      expect { knife.databag_delete([databag_change('mybag', 'item1')]) }
        .not_to raise_error
    end
  end

  describe '#delete_databag_if_empty' do
    it 're-raises when the load error is not a 404 (line 264)' do
      allow(Chef::DataBag).to receive(:load)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.delete_databag_if_empty('mybag') }
        .to raise_error(Net::HTTPClientException)
    end
  end
end
