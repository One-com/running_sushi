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
  describe '#cookbook_delete (error handling)' do
    let(:logger)  { double('logger', info: nil) }
    let(:knife)   { RunningSushi::Knife.new(logger: logger) }
    let(:deleter) do
      double('deleter',
             config: {},
             cookbook_name: nil,
             :config= => nil,
             :cookbook_name= => nil,
             delete_all_without_confirmation: nil,
             delete_version_without_confirmation: nil)
    end

    before do
      allow(Chef::Knife::CookbookDelete).to receive(:new).and_return(deleter)
      allow(Chef::Knife::CookbookDelete).to receive(:load_deps)
    end

    def resp(code)
      double('response', code: code)
    end

    it 'logs "not found" when delete_all_without_confirmation returns 404 (unversioned cookbook, line 320)' do
      allow(deleter).to receive(:delete_all_without_confirmation)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      expect(logger).to receive(:info).with(/mycb  not found. Cannot delete/)
      knife.cookbook_delete([cookbook_change('mycb')])
    end

    it 're-raises a non-404 error from delete_all_without_confirmation (line 319 error arm)' do
      allow(deleter).to receive(:delete_all_without_confirmation)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.cookbook_delete([cookbook_change('mycb')]) }
        .to raise_error(Net::HTTPClientException)
    end

    it 'logs "not found" when delete_version_without_confirmation returns 404 (versioned cookbook, line 320)' do
      allow(deleter).to receive(:delete_version_without_confirmation)
        .and_raise(Net::HTTPClientException.new('404', resp('404')))
      expect(logger).to receive(:info).with(/mycb 1.0.0 not found. Cannot delete/)
      knife.cookbook_delete([cookbook_change('mycb-v1.0.0')])
    end

    it 're-raises a non-404 error from delete_version_without_confirmation (line 319 error arm)' do
      allow(deleter).to receive(:delete_version_without_confirmation)
        .and_raise(Net::HTTPClientException.new('500', resp('500')))
      expect { knife.cookbook_delete([cookbook_change('mycb-v1.0.0')]) }
        .to raise_error(Net::HTTPClientException)
    end
  end
end
