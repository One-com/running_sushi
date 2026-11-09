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

# Unit specs for lib/running_sushi/knife.rb, one group per public method in
# source order. Chef's API classes are verifying doubles and errors come from
# server_error, so nothing here reaches a Chef Server; the real round trips
# are in integration/running_sushi/knife_spec.rb.

require_relative '../spec_helper'
require 'running_sushi/knife'

describe RunningSushi::Knife do
  let(:logger) { class_double(RunningSushi::Log, info: nil, warn: nil) }
  let(:knife) { described_class.new(logger: logger, client_dir: '/repo/clients', databag_dir: '/repo/data_bags') }

  # RunningSushi::Knife exposes no readers for these fields, so these examples
  # read the instance variables. If readers are ever added, prefer those.
  describe '#initialize' do
    # Every option the initializer accepts, set to a non-default value.
    let(:opts) do
      {
        logger: Object.new,
        user: 'sushi',
        host: 'chef.example.com',
        port: 8443,
        pem: '/tmp/sushi.pem',
        client_dir: '/repo/clients',
        cookbook_dirs: ['/repo/cookbooks'],
        databag_dir: '/repo/data_bags',
        environment_dir: '/repo/environments',
        node_dir: '/repo/nodes',
        role_dir: '/repo/roles',
        role_local_dir: '/repo/roles_local',
        checksum_dir: '/repo/checksums',
        master_path: '/var/chef/running_sushi_work',
        base_dir: '/var/chef/running_sushi_work/ops'
      }
    end

    # The named instance variables of +knife+, by name.
    def ivars(knife, names)
      names.to_h { |name| [name, knife.instance_variable_get(:"@#{name}")] }
    end

    context 'without options' do
      it 'uses the defaults' do
        defaults = { logger: nil, user: 'admin', host: 'localhost', port: 443, pem: '/etc/chef-server/admin.pem' }
        expect(ivars(described_class.new, defaults.keys)).to eq(defaults)
      end

      it 'leaves the directories nil' do
        dirs = opts.keys - %i[logger user host port pem]
        expect(ivars(described_class.new, dirs).values).to all(be_nil)
      end
    end

    context 'with every option' do
      it 'stores them' do
        expect(ivars(described_class.new(opts), opts.keys)).to eq(opts)
      end
    end
  end

  describe '#http_api' do
    subject { knife.http_api }

    context 'with Chef::ServerAPI' do
      let(:api) { instance_double(Chef::ServerAPI) }

      before { allow(Chef::ServerAPI).to receive(:new).and_return(api) }

      it { is_expected.to be(api) }
    end

    # Chef::REST was removed in newer Chef versions; stubbing the constant
    # reaches the rescue path without a NameError.
    context 'when Chef::ServerAPI raises' do
      let(:rest_class) { stub_const('Chef::REST', Class.new) }
      let(:rest) { instance_double(rest_class) }

      before do
        allow(Chef::ServerAPI).to receive(:new).and_raise(StandardError)
        allow(rest_class).to receive(:new).and_return(rest)
      end

      it { is_expected.to be(rest) }
    end
  end

  describe '#update_permissions' do
    let(:api) { instance_double(Chef::ServerAPI, put_rest: nil) }

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
      allow(Chef::ServerAPI).to receive(:new).and_return(api)
    end

    context 'without a node of that name' do
      it 'touches no ACL' do
        knife.update_permissions('absent')
        expect(Chef::ServerAPI).not_to have_received(:new)
      end
    end

    context 'when the node is in no ACL yet' do
      let(:data) { acl }

      before { allow(api).to receive(:get_rest).with('nodes/web01/_acl').and_return(data) }

      it 'adds the node to every perm' do
        knife.update_permissions('web01')
        expect(data.transform_values { |p| p['actors'] }).to eq(data.keys.to_h { |perm| [perm, ['web01']] })
      end

      it 'PUTs every perm' do
        knife.update_permissions('web01')
        expect(api).to have_received(:put_rest).exactly(4).times
      end
    end

    context 'when the node already has read' do
      before { allow(api).to receive(:get_rest).and_return(acl(['web01'])) }

      it 'PUTs only the other perms' do
        knife.update_permissions('web01')
        expect(api).to have_received(:put_rest).exactly(3).times
      end
    end

    context 'when a PUT fails' do
      before do
        allow(api).to receive(:get_rest).and_return(acl)
        allow(api).to receive(:put_rest).and_raise(server_error('500'))
      end

      it 'warns' do
        knife.update_permissions('web01')
        expect(logger).to have_received(:warn).with(/Failed to set permission/).at_least(:once)
      end
    end

    # Chef 11 has no ACL endpoint, so the GET fails.
    context 'when the ACL GET fails' do
      before { allow(api).to receive(:get_rest).and_raise(server_error('405')) }

      it 'logs that ACLs are unsupported' do
        knife.update_permissions('web01')
        expect(logger).to have_received(:info).with(/ACL probably not supported/)
      end

      it 'PUTs nothing' do
        knife.update_permissions('web01')
        expect(api).not_to have_received(:put_rest)
      end
    end
  end

  # client_upload replaces a client by destroying it and creating it again; a
  # 404 on destroy means there was nothing to replace.
  describe '#client_upload' do
    subject(:upload) { knife.client_upload([make_change('web01')]) }

    let(:client) do
      instance_double(Chef::ApiClientV1, name: nil, public_key: nil, admin: nil, create: nil, destroy: nil)
    end

    before do
      allow(File).to receive(:read).and_return('{"name":"web01","public_key":"KEY"}')
      allow(Chef::ApiClientV1).to receive(:new).and_return(client)
      # No node named after the client, so update_permissions stops before the
      # ACL API; #update_permissions has its own group above.
      allow(Chef::Node).to receive(:list).and_return({})
    end

    it 'creates the client with its public key' do
      upload
      expect(client).to have_received(:public_key).with('KEY')
    end

    context 'with a node named after the client' do
      let(:api) { instance_double(Chef::ServerAPI) }

      before do
        allow(Chef::Node).to receive(:list).and_return('web01' => 'uri')
        allow(Chef::ServerAPI).to receive(:new).and_return(api)
        allow(api).to receive(:get_rest).and_raise(server_error('405'))
      end

      it 'grants the client access to the node' do
        upload
        expect(api).to have_received(:get_rest).with('nodes/web01/_acl')
      end
    end

    context 'when the client does not exist yet' do
      before { allow(client).to receive(:destroy).and_raise(server_error('404')) }

      it 'creates it' do
        upload
        expect(client).to have_received(:create)
      end

      it 'logs the creation' do
        upload
        expect(logger).to have_received(:info).with(/did not exist, creating/)
      end
    end

    context 'when destroying the client fails' do
      before { allow(client).to receive(:destroy).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { upload }.to raise_error(Net::HTTPClientException)
      end
    end

    context 'when create returns 404' do
      before { allow(client).to receive(:create).and_raise(server_error('404')) }

      it 'warns "Should not be here!"' do
        upload
        expect(logger).to have_received(:warn).with(/Should not be here/)
      end
    end

    context 'when creating the client fails' do
      before { allow(client).to receive(:create).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { upload }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  # The writers below return before logging their "=== ... ===" header when
  # given nothing to do, so a run without changes stays quiet. The one-line
  # wrappers around upload_standard and delete_standard (role_upload,
  # node_delete, ...) only delegate; the integration specs cover them.
  describe '#upload_standard' do
    context 'with an empty list' do
      it 'logs nothing' do
        knife.upload_standard('roles', '/repo/roles', [], Chef::Role)
        expect(logger).not_to have_received(:info)
      end
    end

    # A real Chef::Node, because upload_standard picks nodes out by class.
    context 'with a node' do
      let(:node) { Chef::Node.new.tap { |n| n.name('web01') } }
      let(:api) { instance_double(Chef::ServerAPI) }

      before do
        allow(node).to receive(:save)
        allow(Chef::Knife::Core::ObjectLoader)
          .to receive(:new).and_return(instance_double(Chef::Knife::Core::ObjectLoader, object_from_file: node))
        allow(Chef::Node).to receive(:list).and_return('web01' => 'uri')
        allow(Chef::ServerAPI).to receive(:new).and_return(api)
        allow(api).to receive(:get_rest).and_raise(server_error('405'))
      end

      it 'grants it access to itself' do
        knife.upload_standard('nodes', '/repo/nodes', [make_change('web01')], Chef::Node)
        expect(api).to have_received(:get_rest).with('nodes/web01/_acl')
      end
    end
  end

  describe '#delete_standard' do
    subject(:delete) { knife.delete_standard('roles', [make_change('web01')], Chef::Role) }

    let(:role) { instance_double(Chef::Role, name: nil) }

    before { allow(Chef::Role).to receive(:new).and_return(role) }

    context 'with an empty list' do
      it 'logs nothing' do
        knife.delete_standard('roles', [], Chef::Role)
        expect(logger).not_to have_received(:info)
      end
    end

    context 'when the role is missing' do
      before { allow(role).to receive(:destroy).and_raise(server_error('404')) }

      it 'logs "not found" instead of raising' do
        delete
        expect(logger).to have_received(:info).with(/not found. Cannot delete/)
      end
    end

    context 'when deleting the role fails' do
      before { allow(role).to receive(:destroy).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { delete }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  describe '#databag_upload' do
    context 'with an empty list' do
      it 'logs nothing' do
        knife.databag_upload([])
        expect(logger).not_to have_received(:info)
      end
    end
  end

  describe '#create_databag_if_missing' do
    context 'when the databag exists' do
      before do
        allow(Chef::DataBag).to receive(:load).with('mybag').and_return({ 'item' => {} })
        allow(Chef::DataBag).to receive(:new)
      end

      it 'creates nothing' do
        knife.create_databag_if_missing('mybag')
        expect(Chef::DataBag).not_to have_received(:new)
      end
    end

    context 'when the server returns 404' do
      let(:bag) { instance_double(Chef::DataBag, name: nil, save: nil) }

      before do
        allow(Chef::DataBag).to receive(:load).with('newbag').and_raise(server_error('404'))
        allow(Chef::DataBag).to receive(:new).and_return(bag)
      end

      it 'names the new databag' do
        knife.create_databag_if_missing('newbag')
        expect(bag).to have_received(:name).with('newbag')
      end

      it 'saves it' do
        knife.create_databag_if_missing('newbag')
        expect(bag).to have_received(:save)
      end
    end

    context 'when loading the databag fails' do
      before { allow(Chef::DataBag).to receive(:load).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { knife.create_databag_if_missing('mybag') }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  describe '#databag_delete' do
    subject(:delete) { knife.databag_delete([databag_change('mybag', 'item1')]) }

    let(:item) { instance_double(Chef::DataBagItem) }

    before { allow(Chef::DataBagItem).to receive(:new).and_return(item) }

    context 'with an empty list' do
      it 'logs nothing' do
        knife.databag_delete([])
        expect(logger).not_to have_received(:info)
      end
    end

    context 'when the item is missing' do
      before do
        allow(item).to receive(:destroy).and_raise(server_error('404'))
        # A bag with other items left is kept, so nothing else is deleted.
        allow(Chef::DataBag).to receive(:load).and_return('item2' => 'url')
      end

      it 'logs "not found" instead of raising' do
        delete
        expect(logger).to have_received(:info).with(/not found. Cannot delete/)
      end
    end

    context 'when deleting the item fails' do
      before { allow(item).to receive(:destroy).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { delete }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  describe '#delete_databag_if_empty' do
    context 'when the databag has items' do
      before do
        allow(Chef::DataBag).to receive(:load).with('mybag').and_return({ 'item' => {} })
        allow(Chef::DataBag).to receive(:new)
      end

      it 'deletes nothing' do
        knife.delete_databag_if_empty('mybag')
        expect(Chef::DataBag).not_to have_received(:new)
      end
    end

    context 'when the databag is empty' do
      let(:bag) { instance_double(Chef::DataBag, name: nil, destroy: nil) }

      before do
        allow(Chef::DataBag).to receive(:load).with('emptybag').and_return({})
        allow(Chef::DataBag).to receive(:new).and_return(bag)
      end

      it 'targets that databag' do
        knife.delete_databag_if_empty('emptybag')
        expect(bag).to have_received(:name).with('emptybag')
      end

      it 'destroys it' do
        knife.delete_databag_if_empty('emptybag')
        expect(bag).to have_received(:destroy)
      end
    end

    context 'when the server returns 404' do
      before { allow(Chef::DataBag).to receive(:load).with('missingbag').and_raise(server_error('404')) }

      it 'logs "not found"' do
        knife.delete_databag_if_empty('missingbag')
        expect(logger).to have_received(:info).with(/not found/)
      end
    end

    context 'when loading the databag fails' do
      before { allow(Chef::DataBag).to receive(:load).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { knife.delete_databag_if_empty('mybag') }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  describe '#cookbook_upload' do
    context 'with an empty list' do
      it 'logs nothing' do
        knife.cookbook_upload([])
        expect(logger).not_to have_received(:info)
      end
    end
  end

  describe '#cookbook_version_delete' do
    subject(:delete) { knife.cookbook_version_delete([%w[mycb 1.0.0]]) }

    let(:deleter) do
      instance_double(Chef::Knife::CookbookDelete, config: {}, 'cookbook_name=': nil,
                                                   delete_version_without_confirmation: nil)
    end

    before do
      allow(Chef::Knife::CookbookDelete).to receive_messages(new: deleter, load_deps: nil)
    end

    it 'deletes only the given version' do
      delete
      expect(deleter).to have_received(:delete_version_without_confirmation).with('1.0.0')
    end

    # Without purge the cookbook's files stay in the server's file store.
    it 'purges the files too' do
      delete
      expect(deleter.config).to include(purge: true)
    end

    context 'with an empty list' do
      it 'logs nothing' do
        knife.cookbook_version_delete([])
        expect(logger).not_to have_received(:info)
      end
    end

    context 'when a cookbook version is missing' do
      before { allow(deleter).to receive(:delete_version_without_confirmation).and_raise(server_error('404')) }

      it 'logs "not found"' do
        delete
        expect(logger).to have_received(:info).with(/mycb 1.0.0 not found. Cannot delete/)
      end
    end

    context 'when deleting a version fails' do
      before { allow(deleter).to receive(:delete_version_without_confirmation).and_raise(server_error('500')) }

      it 're-raises the error' do
        expect { delete }.to raise_error(Net::HTTPClientException)
      end
    end
  end

  describe '#cookbook_info' do
    subject { knife.cookbook_info(cookbook_change(dir)) }

    context 'with an unversioned dir' do
      let(:dir) { 'webthing' }

      it { is_expected.to eq(['webthing', nil]) }
    end

    context 'with dashes in an unversioned dir' do
      let(:dir) { 'my-cool-cookbook' }

      it { is_expected.to eq(['my-cool-cookbook', nil]) }
    end

    context 'with a vX.Y.Z tag' do
      let(:dir) { 'morewebthing-v1.5.6' }

      it { is_expected.to eq(%w[morewebthing 1.5.6]) }
    end

    context 'with dashes and a vX.Y.Z tag' do
      let(:dir) { 'my-cool-cookbook-v2.0.0' }

      it { is_expected.to eq(%w[my-cool-cookbook 2.0.0]) }
    end

    context 'with a tag missing the v' do
      let(:dir) { 'cookbook-1.2.3' }

      it { is_expected.to eq(['cookbook-1.2.3', nil]) }
    end

    context 'with an incomplete semver tag' do
      let(:dir) { 'cookbook-v1.2' }

      it { is_expected.to eq(['cookbook-v1.2', nil]) }
    end

    # Only the last dash-segment can be the tag, so anything after it makes
    # the whole dir a name.
    context 'with a segment after the tag' do
      let(:dir) { 'cookbook-v1.2.3-rc1' }

      it { is_expected.to eq(['cookbook-v1.2.3-rc1', nil]) }
    end
  end

  describe '#name_mismatch' do
    subject { knife.name_mismatch('/repo/roles/web.json', name, field: field) }

    let(:field) { 'name' }

    context 'when the name matches the filename' do
      let(:name) { 'web' }

      it { is_expected.to be_nil }
    end

    context 'when the name differs from the filename' do
      let(:name) { 'db' }

      it { is_expected.to eq('/repo/roles/web.json: name "db" in the file does not match the filename') }
    end

    context 'without a name' do
      let(:name) { nil }

      it { is_expected.to include('name nil') }
    end

    context "with field: 'id'" do
      let(:field) { 'id' }
      let(:name) { 'db' }

      it { is_expected.to eq('/repo/roles/web.json: id "db" in the file does not match the filename') }
    end
  end

  describe '#version_mismatch' do
    subject { knife.version_mismatch('/c/web-v1.0.0', tag: tag, version: '1.0.1') }

    context 'without a tag' do
      let(:tag) { nil }

      it { is_expected.to be_nil }
    end

    context 'when the tag matches the metadata version' do
      let(:tag) { '1.0.1' }

      it { is_expected.to be_nil }
    end

    context 'when the tag differs from the metadata version' do
      let(:tag) { '1.0.0' }

      it { is_expected.to eq('/c/web-v1.0.0: metadata version 1.0.1 does not match the directory tag v1.0.0') }
    end
  end

  describe '#cookbook_name_mismatch' do
    subject { knife.cookbook_name_mismatch('/web', name: 'web', metadata_name: metadata_name) }

    context 'when the metadata name matches' do
      let(:metadata_name) { 'web' }

      it { is_expected.to be_nil }
    end

    context 'when the metadata name differs' do
      let(:metadata_name) { 'apache2' }

      it { is_expected.to eq('/web: metadata name "apache2" does not match the cookbook name web from the directory') }
    end

    context 'without a metadata name' do
      let(:metadata_name) { nil }

      it { is_expected.to eq('/web: metadata name nil does not match the cookbook name web from the directory') }
    end
  end

  describe '#verify_node_upload' do
    subject { knife.verify_node_upload('web01', 'abc123') }

    def server_node(checkpoint)
      instance_double(Chef::Node, normal: { 'running_sushi' => { 'checkpoint' => checkpoint } })
    end

    context 'when the server checkpoint matches' do
      before { allow(Chef::Node).to receive(:load).with('web01').and_return(server_node('abc123')) }

      it { is_expected.to be(true) }
    end

    context 'when the server checkpoint differs' do
      before { allow(Chef::Node).to receive(:load).with('web01').and_return(server_node('old_rev')) }

      it { is_expected.to be(false) }
    end

    context 'when loading the node fails' do
      before { allow(Chef::Node).to receive(:load).and_raise(StandardError, 'node not found') }

      it { is_expected.to be(false) }
    end
  end
end
