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

require 'set'
require 'running_sushi/git_state'
require 'running_sushi/knife'

module RunningSushi
  # The diff mode: applies what changed in Git between two revisions, for
  # all seven kinds, content changes included, deleting only what the diff
  # deleted. Roles, nodes, clients and environments are decided by name
  # (.changes_by_name), cookbook versions by .cookbook_deletes.
  #
  # .plan reads only through its arguments (the lazy Git listing and the
  # Knife), the way Reconcile.compare does; .apply writes through the Knife.
  # Everything else is pure.
  #
  # ModuleLength: the module is the whole diff mode; splitting off its
  # cookbook or name rules would scatter one plan over several modules.
  # rubocop:disable-next Metrics/ModuleLength
  module Diff
    # What one run changes. +uploads+ maps each Knife#check_uploads kind to
    # the ChefDiff changes to upload; +deletes+ maps the kinds that delete to
    # what their Knife delete method takes ([name, version] pairs for
    # :cookbooks). +deleted_cookbooks+ holds the deleted cookbook dirs, for
    # the report only; +checks+ is the argument for Knife#check_uploads.
    Plan = Struct.new(:uploads, :deletes, :deleted_cookbooks, :checks, keyword_init: true)

    # Returns the Plan for +changeset+, the ChefDiff::Changeset of the diff.
    # +tree+ returns the ChefDiff::Changeset of every file in Git, built with
    # the same directories; it is only called when the diff touched a role,
    # node, client, environment or deleted cookbook, since listing the tree
    # is the expensive part. +knife+ is read for cookbook ids and server
    # versions only when a cookbook dir was deleted. +local_roles+ says
    # whether local roles count at all; +extra_nodes+ are node names to
    # upload again although the diff didn't touch them (see .named_changes).
    #
    # Raises GitState::DuplicateNameError when a touched name has two files
    # of one kind.
    def self.plan(changeset, tree, knife, local_roles:, extra_nodes:)
      cookbooks, deleted_cookbooks = split_by_status(changeset.cookbooks)
      role_uploads, deleted_roles = role_changes(changeset, tree, local_roles: local_roles)
      others = other_changes(changeset, tree, extra_nodes)
      uploads = { cookbooks: cookbooks }.merge(role_uploads, others.transform_values(&:first))
      deletes = { cookbooks: deleted_cookbook_versions(knife, deleted_cookbooks, tree), roles: deleted_roles }
                .merge(others.transform_values(&:last))
      Plan.new(uploads: uploads, deletes: deletes, deleted_cookbooks: deleted_cookbooks,
               checks: checks(uploads, changeset.roles))
    end

    # Returns { kind => [to upload, to delete] } for databags, decided per
    # file, and for nodes, environments and clients, decided by name (see
    # .named_changes; +extra_nodes+ are re-queued node names).
    def self.other_changes(changeset, tree, extra_nodes)
      {
        databags: split_by_status(changeset.databags),
        nodes: named_changes(:nodes, changeset.nodes, tree, extra_names: extra_nodes),
        environments: named_changes(:environments, changeset.environments, tree),
        clients: named_changes(:clients, changeset.clients, tree)
      }
    end

    # The argument for Knife#check_uploads: +uploads+, plus every global role
    # the diff changed (+changed_roles+, ChefDiff changes), including one
    # that loses to a local role and is not uploaded. A mismatch in it fails
    # this run as it fails servers without that local role, and as it fails
    # reconcile.
    def self.checks(uploads, changed_roles)
      roles = uploads.fetch(:roles) + split_by_status(changed_roles).first
      uploads.merge(roles: roles.uniq(&:full_name))
    end

    # Returns the report lines for +plan+, one per list, in a fixed order.
    # One line per list keeps each label next to where its list comes from.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def self.report(plan)
      uploads = plan.uploads
      deletes = plan.deletes
      {
        'Added cookbooks' => uploads.fetch(:cookbooks),
        'Deleted cookbooks' => plan.deleted_cookbooks,
        'Deleted cookbook versions' => deletes.fetch(:cookbooks),
        'Added roles' => uploads.fetch(:roles),
        'Deleted roles' => deletes.fetch(:roles),
        'Added local roles' => uploads.fetch(:roles_local),
        'Added databags' => uploads.fetch(:databags),
        'Deleted databags' => deletes.fetch(:databags),
        'Added nodes' => uploads.fetch(:nodes),
        'Deleted nodes' => deletes.fetch(:nodes),
        'Added environments' => uploads.fetch(:environments),
        'Deleted environments' => deletes.fetch(:environments),
        'Added clients' => uploads.fetch(:clients),
        'Deleted clients' => deletes.fetch(:clients)
      }.map { |label, list| "#{label}: #{list}" }
    end

    # Writes +plan+ to the Chef Server through +knife+, stamping uploaded
    # nodes with +rev+, and yields the uploaded nodes right after their
    # upload so the caller can record them for verification.
    #
    # The order is deliberate: cookbook versions are deleted first, roles
    # are deleted before roles are uploaded, and each other kind deletes
    # before it uploads. Unlike Reconcile.apply, uploads do not all come
    # first; changing the order changes what a failed run leaves on the
    # server. Every method is called even with an empty list; the Knife
    # methods return early then.
    # One line per write keeps the order readable at a glance, which a
    # table-driven loop would hide behind the node special case.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def self.apply(knife, plan, rev)
      uploads = plan.uploads
      deletes = plan.deletes
      knife.cookbook_version_delete(deletes.fetch(:cookbooks))
      knife.cookbook_upload(uploads.fetch(:cookbooks))
      knife.role_delete(deletes.fetch(:roles))
      knife.role_upload(uploads.fetch(:roles))
      knife.role_local_upload(uploads.fetch(:roles_local))
      knife.databag_delete(deletes.fetch(:databags))
      knife.databag_upload(uploads.fetch(:databags))
      knife.node_delete(deletes.fetch(:nodes))
      knife.node_upload(uploads.fetch(:nodes), rev)
      yield uploads.fetch(:nodes)
      knife.environment_delete(deletes.fetch(:environments))
      knife.environment_upload(uploads.fetch(:environments))
      knife.client_delete(deletes.fetch(:clients))
      knife.client_upload(uploads.fetch(:clients))
    end

    # Splits ChefDiff +changes+ into [to upload, to delete]. ChefDiff sets
    # only :modified or :deleted, so anything not deleted is uploaded.
    def self.split_by_status(changes)
      changes.partition { |change| change.status != :deleted }
    end

    # Returns [{ roles: changes, roles_local: changes }, NameRefs] for the
    # roles +changeset+ touched: the winning file of each name to upload,
    # split by kind, and the role names to delete (see .changes_by_name).
    # Local roles count only with +local_roles+.
    #
    # An object's name is its file's basename: Knife#check_uploads refuses an
    # upload whose name differs, and a deleted file can no longer be read.
    # ChefDiff's Change#name is not it for roles, since for roles/sub/web.json
    # it is sub/web. The listing of every file comes from git ls-files, so
    # untracked files and files outside a sparse checkout never count.
    def self.role_changes(changeset, tree, local_roles:)
      local = local_roles ? changeset.roles_local : []
      touched = (changeset.roles + local).map { |change| File.basename(change.full_name) }
      return [{ roles: [], roles_local: [] }, []] if touched.empty?

      uploads, gone = changes_by_name(touched, role_items(tree.call, local_roles))
      [changes_by_kind(uploads, %i[roles roles_local]), gone.map { |name| Knife::NameRef.new(name) }]
    end

    # Returns { kind => changes } for each of +kinds+, from the Items +items+.
    def self.changes_by_kind(items, kinds)
      kinds.to_h { |kind| [kind, items.select { |item| item.kind == kind }.map(&:change)] }
    end

    # Every role file in the Git listing +tree+, global and, with
    # +local_roles+, local, as GitState::Items named after their basename.
    def self.role_items(tree, local_roles)
      local = local_roles ? tree.roles_local : []
      { roles: tree.roles, roles_local: local }.flat_map { |kind, changes| named_items(kind, changes) }
    end

    # Wraps +changes+ of +kind+ as GitState::Items named after their file's
    # basename, the object's name on the Chef Server (see .role_changes).
    def self.named_items(kind, changes)
      changes.map do |change|
        GitState::Item.new(id: File.basename(change.full_name), kind: kind, change: change)
      end
    end

    # The node, client or environment counterpart of .role_changes: returns
    # [changes to upload, NameRefs to delete] for the objects of +kind+ (a
    # ChefDiff::Changeset method) that +diff_changes+ or +extra_names+ touch,
    # decided by name against every file of +kind+ in +tree+. A move between
    # subdirectories therefore uploads from the new file and deletes nothing,
    # and a name with two files raises GitState::DuplicateNameError.
    #
    # Only names from the diff are deleted; an +extra_names+ name with no
    # file is skipped. The diff already lists every file deleted in Git, so
    # an extra name can only have lost its file because the tracked tree
    # changed under it (a new pod_name or node_path), and its file may well
    # still exist outside the tree.
    def self.named_changes(kind, diff_changes, tree, extra_names: [])
      diff_names = diff_changes.map { |change| File.basename(change.full_name) }
      touched = diff_names + extra_names
      return [[], []] if touched.empty?

      uploads, gone = changes_by_name(touched, named_items(kind, tree.call.public_send(kind)))
      [uploads.map(&:change), (gone & diff_names).map { |name| Knife::NameRef.new(name) }]
    end

    # The name rule, for roles and for nodes, clients and environments
    # alike. Returns [uploads, deletes] for the names in +touched+ (those the
    # diff changed, plus any the caller re-queues): the winning
    # GitState::Item (see GitState.sources) of each name a file in Git still
    # claims, and the names no file claims any more. +items+ are every file
    # in Git of the kinds +touched+ is about.
    #
    # Deciding by name rather than by path is what makes a local role win
    # when either file sits in a subdirectory: roles/sub/web.json and
    # roles_local/pod1/web.json are both the role web, but their paths never
    # line up. It also turns a file moved between subdirectories, which Git
    # reports as a delete plus a create, into one upload and no delete.
    # Re-uploading the winner of a name whose loser changed costs one upload
    # and repairs a winner overwritten earlier.
    #
    # Raises GitState::DuplicateNameError when a touched name has two files
    # of one kind; a duplicate the diff didn't touch is left alone, as
    # Knife#check_uploads leaves unchanged files alone.
    def self.changes_by_name(touched, items)
      # A Set, so a diff touching thousands of nodes stays linear.
      touched_names = touched.to_set
      GitState.unique_names!(items.select { |item| touched_names.include?(item.id) })
      winners = GitState.sources(items)
      kept, gone = touched.uniq.partition { |name| winners.key?(name) }
      [kept.map { |name| winners.fetch(name) }, gone]
    end

    # Returns .cookbook_deletes for the cookbook dirs in +deleted+ (ChefDiff
    # changes): the server versions no cookbook dir in Git still provides.
    # Calls +tree+ and reads the server only when a cookbook dir was deleted.
    #
    # Only the metadata of dirs named after a deleted cookbook is loaded (by
    # Knife#cookbook_info, version tag stripped). A dir of another name can
    # only provide the cookbook through a metadata name that contradicts its
    # dir, which is left to reconcile; and loading it would let one untouched
    # cookbook the current Chef can't load (after a Chef upgrade, or once its
    # path joins cookbook_paths) fail every run that deletes a cookbook.
    def self.deleted_cookbook_versions(knife, deleted, tree)
      return [] if deleted.empty?

      targets = deleted.map { |change| knife.cookbook_info(change) }
      names = targets.map { |name, _tag| name }
      same_name = tree.call.cookbooks.select { |change| names.include?(knife.cookbook_info(change).first) }
      cookbook_deletes(targets, in_git: knife.cookbook_ids(same_name), on_server: knife.server_cookbook_versions)
    end

    # The cookbook delete rule, Reconcile.diff's "extra" rule limited to the
    # cookbook dirs the diff deleted. Returns the sorted [name, version]
    # pairs to delete.
    #
    # +deleted+ holds Knife#cookbook_info's [name, tag] of each deleted dir;
    # a nil tag (an unversioned dir) stands for every version of name in
    # +on_server+. Versions in +in_git+, the ids of every cookbook dir in Git,
    # are kept: an unversioned nginx renamed to nginx-v2.0.0, or deleted next
    # to nginx-v1.0.0, must not take the pinned versions with it.
    def self.cookbook_deletes(deleted, in_git:, on_server:)
      candidates = deleted.flat_map do |name, tag|
        tag ? [[name, tag]] : on_server.select { |server_name, _version| server_name == name }
      end
      (candidates - in_git).uniq.sort
    end
  end
end
