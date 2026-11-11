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

# Integration specs for lib/running_sushi/knife.rb.
#
# Each example runs a real Chef API flow against the in-process ChefZero
# server started by integration_helper.rb, reading the fixtures under
# spec/fixtures. No stubs are used. integration_helper.rb clears the server
# before every example, so each one starts from an empty server.

require_relative '../integration_helper'

describe RunningSushi::Knife do
  # What the knife logs, for the "not found" messages of the deletes.
  let(:log) { StringIO.new }
  let(:knife) { build_knife(logger: Logger.new(log)) }

  describe '#role_upload' do
    it 'uploads the role from roles/' do
      knife.role_upload([make_change('test-role')])
      expect(Chef::Role.list).to include('test-role')
    end
  end

  describe '#role_delete' do
    context 'with the role on the server' do
      before { knife.role_upload([make_change('test-role')]) }

      it 'deletes it' do
        expect { knife.role_delete([make_change('test-role')]) }
          .to change { Chef::Role.list.include?('test-role') }.from(true).to(false)
      end
    end

    context 'without the role on the server' do
      it 'logs "not found"' do
        knife.role_delete([make_change('nonexistent-role')])
        expect(log.string).to include('roles nonexistent-role not found. Cannot delete')
      end
    end
  end

  # role_local_upload is a thin wrapper around the standard upload pipeline
  # pointed at a different on-disk directory. This makes sure the file
  # resolution actually lands on roles_local/.
  describe '#role_local_upload' do
    it 'uploads the role from roles_local/' do
      knife.role_local_upload([make_change('local-role')])
      expect(Chef::Role.list).to include('local-role')
    end
  end

  describe '#environment_upload' do
    it 'uploads the environment' do
      knife.environment_upload([make_change('test-env')])
      expect(Chef::Environment.list).to include('test-env')
    end
  end

  describe '#environment_delete' do
    context 'with the environment on the server' do
      before { knife.environment_upload([make_change('test-env')]) }

      it 'deletes it' do
        expect { knife.environment_delete([make_change('test-env')]) }
          .to change { Chef::Environment.list.include?('test-env') }.from(true).to(false)
      end
    end

    context 'without the environment on the server' do
      it 'logs "not found"' do
        knife.environment_delete([make_change('nonexistent-env')])
        expect(log.string).to include('environments nonexistent-env not found. Cannot delete')
      end
    end
  end

  describe '#node_upload' do
    before { knife.node_upload([make_change('web01')], 'sha_abc') }

    it 'uploads the node' do
      expect(Chef::Node.list).to include('web01')
    end

    it 'stamps the revision into node.normal' do
      expect(Chef::Node.load('web01').normal['running_sushi']['checkpoint']).to eq('sha_abc')
    end
  end

  describe '#node_delete' do
    context 'with the node on the server' do
      before { knife.node_upload([make_change('web01')], 'sha_abc') }

      it 'deletes it' do
        expect { knife.node_delete([make_change('web01')]) }
          .to change { Chef::Node.list.include?('web01') }.from(true).to(false)
      end
    end

    context 'without the node on the server' do
      it 'logs "not found"' do
        knife.node_delete([make_change('nonexistent-node')])
        expect(log.string).to include('nodes nonexistent-node not found. Cannot delete')
      end
    end
  end

  describe '#verify_node_upload' do
    subject { knife.verify_node_upload('web01', 'sha_match') }

    context 'when the stored checkpoint matches' do
      before { knife.node_upload([make_change('web01')], 'sha_match') }

      it { is_expected.to be(true) }
    end

    context 'when the stored checkpoint differs' do
      before { knife.node_upload([make_change('web01')], 'sha_other') }

      it { is_expected.to be(false) }
    end

    context 'without the node on the server' do
      it { is_expected.to be(false) }
    end
  end

  describe '#databag_upload' do
    context 'without the bag on the server' do
      it 'creates the bag with the item' do
        knife.databag_upload([databag_change('my-bag', 'my-item')])
        expect(Chef::DataBag.load('my-bag')).to include('my-item')
      end
    end

    context 'with the bag on the server' do
      before { knife.databag_upload([databag_change('my-bag', 'my-other-item')]) }

      it 'adds the item next to the others' do
        knife.databag_upload([databag_change('my-bag', 'my-item')])
        expect(Chef::DataBag.load('my-bag').keys).to contain_exactly('my-item', 'my-other-item')
      end
    end
  end

  describe '#databag_delete' do
    context 'with the last item of the bag' do
      before { knife.databag_upload([databag_change('my-bag', 'my-item')]) }

      it 'removes the bag' do
        expect { knife.databag_delete([databag_change('my-bag', 'my-item')]) }
          .to change { Chef::DataBag.list.include?('my-bag') }.from(true).to(false)
      end
    end

    context 'with other items left' do
      before do
        knife.databag_upload([databag_change('my-bag', 'my-item'), databag_change('my-bag', 'my-other-item')])
      end

      # One matcher for "the bag exists, kept the other item, lost the deleted one".
      it 'keeps the bag with the others' do
        knife.databag_delete([databag_change('my-bag', 'my-item')])
        expect(Chef::DataBag.load('my-bag').keys).to contain_exactly('my-other-item')
      end
    end

    context 'without the item on the server' do
      it 'logs "not found"' do
        knife.databag_delete([databag_change('my-bag', 'nonexistent-item')])
        expect(log.string).to include('nonexistent-item not found. Cannot delete')
      end
    end
  end

  describe '#client_upload' do
    context 'without the client on the server' do
      it 'creates it' do
        knife.client_upload([make_change('test-client')])
        expect(Chef::ApiClientV1.list).to include('test-client')
      end
    end

    # test-client-rotated.json keeps the same internal `name` as the plain
    # test-client fixture but sets `admin`, so only a working
    # delete-then-create cycle changes the flag on the server.
    context 'with the client on the server' do
      before { knife.client_upload([make_change('test-client')]) }

      it 'replaces it' do
        expect { knife.client_upload([make_change('test-client-rotated')]) }
          .to change { Chef::ApiClientV1.load('test-client').admin }.from(false).to(true)
      end
    end
  end

  describe '#client_delete' do
    before { knife.client_upload([make_change('test-client')]) }

    it 'deletes the client' do
      expect { knife.client_delete([make_change('test-client')]) }
        .to change { Chef::ApiClientV1.list.include?('test-client') }.from(true).to(false)
    end
  end

  describe '#cookbook_upload' do
    context 'with an unversioned dir' do
      it 'uploads the cookbook' do
        knife.cookbook_upload([cookbook_change('test-cookbook')])
        expect(Chef::CookbookVersion.list).to include('test-cookbook')
      end
    end

    # Uploads only the suffixed directory: with v1.0.0 also on the server the
    # name check would pass even if the tag were not stripped.
    context 'with a version-tagged dir' do
      it 'strips the tag from the name' do
        knife.cookbook_upload([cookbook_change('test-cookbook-v2.0.0')])
        expect(Chef::CookbookVersion.list).to include('test-cookbook')
      end
    end
  end

  # Chef's knife UI reports each deleted version on the real STDERR; the
  # output matcher only keeps the run quiet. `anything` also matches no
  # output, so a bare `output` would fail if Chef stopped printing.
  describe '#cookbook_version_delete' do
    # The versions of test-cookbook on the server; [] once it is gone.
    def versions
      Chef::CookbookVersion.list_all_versions.fetch('test-cookbook', {})
                           .fetch('versions', []).map { |v| v['version'] }
    end

    before do
      knife.cookbook_upload([cookbook_change('test-cookbook')])         # v1.0.0
      knife.cookbook_upload([cookbook_change('test-cookbook-v2.0.0')])  # v2.0.0
    end

    it 'deletes only the given version' do
      expect { knife.cookbook_version_delete([%w[test-cookbook 2.0.0]]) }
        .to change { versions }.from(contain_exactly('1.0.0', '2.0.0')).to(['1.0.0'])
        .and output(anything).to_stderr_from_any_process
    end

    # A version deleted by hand must not fail the run that deletes its dir.
    context 'with a version not on the server' do
      it 'logs "not found"' do
        knife.cookbook_version_delete([%w[test-cookbook 3.0.0]])
        expect(log.string).to include('test-cookbook 3.0.0 not found. Cannot delete')
      end
    end
  end

  describe '#cookbook_ids' do
    subject { knife.cookbook_ids(dirs.map { |dir| cookbook_change(dir) }) }

    context 'with consistent dirs' do
      let(:dirs) { %w[test-cookbook test-cookbook-v2.0.0] }

      it { is_expected.to eq([%w[test-cookbook 1.0.0], %w[test-cookbook 2.0.0]]) }
    end

    # #check_uploads raises for both; the diff path must not.
    context 'with dirs that contradict their path' do
      let(:dirs) { %w[misnamed-cookbook test-cookbook-v3.0.0] }

      it { is_expected.to eq([%w[other-cookbook 1.0.0], %w[test-cookbook 3.0.1]]) }
    end
  end

  # Files whose contents contradict their path (a JSON `name` or data bag
  # item `id` that differs from the filename, a cookbook dir name or tag that
  # differs from the metadata name or version) must fail the run before
  # anything is written. Uploading them would create an object that deleting
  # the file can never remove, because deletes go by the path.
  #
  # This lives with the integration specs for the real fixtures and
  # CookbookVersionLoader; #check_uploads itself never talks to the server.
  describe '#check_uploads' do
    subject(:check) { knife.check_uploads(changes) }

    {
      roles: ['misnamed-role', 'roles/misnamed-role.json', 'test-role'],
      roles_local: ['misnamed-local-role', 'roles_local/misnamed-local-role.json', 'local-role'],
      environments: ['misnamed-env', 'environments/misnamed-env.json', 'test-env'],
      nodes: ['misnamed-node', 'nodes/misnamed-node.json', 'web01'],
      clients: ['misnamed-client', 'clients/misnamed-client.json', 'test-client']
    }.each do |kind, (bad, file, good)|
      context "with a mismatched #{kind} file" do
        let(:changes) { { kind => [make_change(good), make_change(bad)] } }

        it 'names the file' do
          expect { check }.to raise_error(described_class::MismatchError, /#{Regexp.escape(file)}/)
        end
      end

      context "with only matching #{kind} files" do
        let(:changes) { { kind => [make_change(good)] } }

        it 'passes' do
          expect { check }.not_to raise_error
        end
      end
    end

    context 'with a mismatched data bag item' do
      let(:changes) { { databags: [databag_change('my-bag', 'my-item'), databag_change('my-bag', 'misnamed-item')] } }

      it 'names the file' do
        expect { check }.to raise_error(described_class::MismatchError, %r{data_bags/my-bag/misnamed-item\.json})
      end
    end

    context 'with a cookbook tag unlike its metadata' do
      let(:changes) { { cookbooks: %w[test-cookbook-v2.0.0 test-cookbook-v3.0.0].map { |d| cookbook_change(d) } } }

      it 'names the file' do
        expect { check }.to raise_error(described_class::MismatchError, %r{cookbooks/test-cookbook-v3\.0\.0})
      end
    end

    context 'with a cookbook dir unlike its metadata name' do
      let(:changes) { { cookbooks: %w[test-cookbook misnamed-cookbook].map { |d| cookbook_change(d) } } }

      it 'names the file' do
        expect { check }.to raise_error(described_class::MismatchError, %r{cookbooks/misnamed-cookbook})
      end
    end

    context 'with a cookbook dir without metadata' do
      let(:changes) { { cookbooks: [cookbook_change('not-a-cookbook')] } }

      it 'names the dir' do
        expect { check }.to raise_error(described_class::MismatchError, %r{cookbooks/not-a-cookbook: metadata name nil})
      end
    end

    context 'with matching data bag items and cookbooks' do
      let(:changes) do
        { databags: [databag_change('my-bag', 'my-item')], cookbooks: [cookbook_change('test-cookbook-v2.0.0')] }
      end

      it 'returns what each file creates' do
        expect(check).to eq(databags: [%w[my-bag my-item]], cookbooks: [%w[test-cookbook 2.0.0]])
      end
    end

    context 'without changes' do
      let(:changes) { {} }

      it 'passes' do
        expect { check }.not_to raise_error
      end
    end

    context 'with several mismatches' do
      let(:changes) { { roles: [make_change('misnamed-role')], nodes: [make_change('misnamed-node')] } }

      it 'names every offending file' do
        expect { check }.to raise_error(described_class::MismatchError, /misnamed-role.*\n.*misnamed-node/)
      end
    end
  end
end
