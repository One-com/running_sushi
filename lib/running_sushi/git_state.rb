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

module RunningSushi
  # The rules for what Git says should exist on the Chef Server, shared by
  # the diff mode (RunningSushi::Diff) and the reconcile mode
  # (RunningSushi::Reconcile): an object's name is its identity, a local role
  # wins over the global role of the same name, and a name may have only one
  # file per kind. Pure: .unique_names! may raise, but nothing here does I/O.
  module GitState
    # One file in Git: +id+, what uploading it creates (Knife#check_uploads),
    # the ChefDiff change and the kind (a Knife#check_uploads key; for
    # reconcile a Reconcile::UPLOADERS key) to upload it with.
    Item = Struct.new(:id, :kind, :change, keyword_init: true)

    # Raised by .unique_names!; the message lists every clashing file.
    class DuplicateNameError < StandardError; end

    # What an Item of each kind is on the Chef Server, for error messages.
    NOUNS = { roles: 'role', roles_local: 'role', nodes: 'node', clients: 'client',
              environments: 'environment' }.freeze

    # Returns { id => Item } for the files to upload each id from. A local
    # role wins over the global role of the same name.
    def self.sources(items)
      local, other = items.partition { |item| item.kind == :roles_local }
      (other + local).to_h { |item| [item.id, item] }
    end

    # Raises DuplicateNameError when two +items+ of one kind share an id,
    # e.g. roles/a/web.json and roles/b/web.json. Each kind has one
    # namespace on the Chef Server, so only one of them can be the role web;
    # which one would depend on the order Git lists them in (.sources keeps
    # the last), and editing the other would silently upload nothing new. A
    # global and a local role sharing a name is the override, not a clash,
    # and a node and a client sharing one are two different objects.
    def self.unique_names!(items)
      clashes = items.group_by { |item| [item.kind, item.id] }.filter_map do |(kind, id), group|
        next if group.size < 2

        files = group.map { |item| "#{item.change.full_name}.json" }
        "#{kind}: #{NOUNS.fetch(kind)} #{id} is defined by more than one file: #{files.join(', ')}"
      end
      raise DuplicateNameError, clashes.join("\n") unless clashes.empty?
    end
  end
end
