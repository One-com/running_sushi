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

require 'running_sushi/git_state'
require 'running_sushi/knife'

module RunningSushi
  # Makes the Chef Server match Git for the TYPES the caller selects
  # (cookbooks, roles global and local, environments, nodes, clients, data
  # bag items): uploads objects missing from the server and deletes extra
  # objects (or cookbook versions) on it, e.g. after deletes or uploads made
  # with knife by hand. The diff
  # path never sees those, because it only applies what changed in Git. Only
  # existence is compared; an object whose content was changed by hand stays
  # as it is.
  #
  # Each file is compared by what uploading it would create, not by its
  # path, so the comparison matches what is actually on the server. The ids
  # come from Knife#check_uploads, which also fails the reconcile when any
  # file contradicts its path, the same rule as on the diff path.
  #
  # What Git says should exist follows the rules in GitState, shared with the
  # diff path (RunningSushi::Diff). .checks, .check, .diff, .guard and
  # .report are pure; .compare reads and logs, .apply writes through the
  # same Knife methods as the diff path.
  module Reconcile
    Drift = Struct.new(:missing, :extra, keyword_init: true)

    # One type compared. +type+ is a TYPES key, +actual+ holds the ids on the
    # server, +blocked+ says why its extras must not be deleted (nil when they
    # may).
    Check = Struct.new(:type, :items, :actual, :drift, :blocked, keyword_init: true)

    # What reconcile knows of each type, keyed by the name --reconcile=TYPES
    # takes. +noun+ names one object in log lines. +kinds+ are the
    # Knife#check_uploads kinds (and ChefDiff::Changeset methods) whose files
    # make up the type; only the first is guarded (see .empty_dirs), under
    # the changeset location +dir+. +list+ is the Knife method returning the
    # ids on the server, +delete+ the one deleting extras, each turned into
    # its argument by +ref+ (default: a Knife::NameRef of the name, or of the
    # [bag, item] pair). Ids matching +keep+ (optional) exist on a server
    # without a file in Git and are never compared (see .checks): the _default
    # environment, the validator client (chef-validator, or <org>-validator
    # since Chef Server 12) and Chef 11's chef-webui client.
    TYPES = {
      cookbooks: { noun: 'cookbook', kinds: %i[cookbooks], dir: :cookbook_dirs,
                   list: :server_cookbook_versions, delete: :cookbook_version_delete, ref: :itself.to_proc },
      roles: { noun: 'role', kinds: %i[roles roles_local], dir: :role_dir,
               list: :server_role_names, delete: :role_delete },
      environments: { noun: 'environment', kinds: %i[environments], dir: :environment_dir,
                      list: :server_environment_names, delete: :environment_delete, keep: /\A_default\z/ },
      nodes: { noun: 'node', kinds: %i[nodes], dir: :node_dir, list: :server_node_names, delete: :node_delete },
      clients: { noun: 'client', kinds: %i[clients], dir: :client_dir,
                 list: :server_client_names, delete: :client_delete, keep: /\A(.+-validator|chef-webui)\z/ },
      databags: { noun: 'data bag item', kinds: %i[databags], dir: :databag_dir,
                  list: :server_databag_items, delete: :databag_delete }
    }.freeze

    UPLOADERS = { cookbooks: :cookbook_upload, roles: :role_upload, roles_local: :role_local_upload,
                  environments: :environment_upload, nodes: :node_upload, clients: :client_upload,
                  databags: :databag_upload }.freeze

    # +items+ are the Items of every file in Git for +type+; +actual+ the
    # ids of that type on the server; +empty_dirs+ the guarded directories
    # with nothing in Git (see .guard).
    def self.check(type, items:, actual:, empty_dirs:)
      drift = diff(items, actual)
      Check.new(type: type, items: items, actual: actual, drift: drift, blocked: guard(drift, empty_dirs))
    end

    # Returns the sorted ids missing from and extra on the server. Only
    # +missing+ needs uniq: a role can be in Git both global and local,
    # while the server lists each id once.
    def self.diff(items, actual)
      desired = items.map(&:id)
      Drift.new(missing: (desired - actual).uniq.sort, extra: (actual - desired).sort)
    end

    # Returns why the extras in +drift+ must not be deleted, nil when they
    # may. Deletes of a type are refused when any of its directories has
    # nothing in Git (+empty_dirs+): that is what a broken checkout (empty
    # clone, wrong cookbook_paths or role_path, a sparse-checkout mistake)
    # looks like, and deleting would empty the server of everything from that
    # directory. Checking the type as a whole would miss it while another
    # directory still has files. Any other amount of extras is deleted, since
    # running with --reconcile asks for exactly that.
    def self.guard(drift, empty_dirs)
      "nothing in Git under #{empty_dirs.join(', ')}" unless drift.extra.empty? || empty_dirs.empty?
    end

    # Returns the log lines for +check+, as [level, message] pairs: a warning
    # per drift item, an error when the guard blocks the deletes, and a
    # summary with the counts.
    def self.report(check)
      noun = TYPES.fetch(check.type)[:noun]
      blocked = check.blocked ? [[:error, "Reconcile: not deleting extra #{noun}s: #{check.blocked}"]] : []
      drift_lines(check, noun) + blocked + [[:warn, summary(check, noun)]]
    end

    def self.drift_lines(check, noun)
      check.drift.to_h.flat_map do |side, ids|
        ids.map { |id| [:warn, "Reconcile: #{side} #{noun} #{label(id)}"] }
      end
    end

    def self.summary(check, noun)
      in_git = check.items.map(&:id).uniq.size
      "Reconcile: #{noun}: #{in_git} in Git, #{check.actual.size} on server, " \
        "#{check.drift.missing.size} missing, #{check.drift.extra.size} extra"
    end

    # A cookbook id is [name, version]; a role id is its name.
    def self.label(id)
      Array(id).join(' ')
    end

    # Compares the +types+ (TYPES keys) in +changeset+, a ChefDiff::Changeset
    # listing every file in Git, with the server through +knife+; types left
    # out are neither checked in Git nor listed on the server. +locations+
    # are the directories +changeset+ was built with. Without +local_roles+
    # the local roles in Git are ignored, as if there were none, so
    # local-only roles on the server count as extra.
    # Logs the report to +logger+ and returns the Checks for .apply. Raises,
    # before reading the server, Knife::MismatchError when any of the files
    # contradicts its path and GitState::DuplicateNameError when two files
    # of one kind share a name.
    #
    # ParameterLists: the two keywords are independent settings of one run;
    # bundling them into an options object would only rename the problem.
    # rubocop:disable-next Metrics/ParameterLists
    def self.compare(knife, changeset, logger, locations, local_roles:, types:)
      items = items_in_git(knife, changeset, local_roles, types)
      GitState.unique_names!(items.slice(*GitState::NOUNS.keys).values.flatten(1))
      result = checks(items, locations, types.to_h { |type| [type, knife.public_send(TYPES.fetch(type)[:list])] })
      result.flat_map { |c| report(c) }.each { |level, message| logger.public_send(level, message) }
      result
    end

    # Returns a Check per type in +actual+ ({ TYPES key => ids on the
    # server }), in its order, for +items+ (as from .items_in_git) read from
    # +locations+. Built-in ids are compared on neither side (see .git_items).
    def self.checks(items, locations, actual)
      actual.map do |type, ids|
        kinds, dir = TYPES.fetch(type).values_at(:kinds, :dir)
        git = git_items(type, items)
        empty = empty_dirs(kinds.first, git.fetch(kinds.first), Array(locations[dir]))
        check(type, items: git.values.flatten(1), actual: ids.reject { |id| built_in?(type, id) }, empty_dirs: empty)
      end
    end

    # { kind => [Item] } of +items+ for the kinds of +type+, without its
    # built-in ids. A file for one would otherwise be missing on every run,
    # and uploading it fails (_default) or destroys and recreates it (a
    # validator). Left out before the guard, so such a file alone counts as
    # an empty dir.
    def self.git_items(type, items)
      items.slice(*TYPES.fetch(type)[:kinds]).transform_values { |list| list.reject { |i| built_in?(type, i.id) } }
    end

    # Whether +id+ matches the +keep+ of +type+ (see TYPES).
    def self.built_in?(type, id)
      TYPES.fetch(type)[:keep]&.match?(id)
    end

    # The +dirs+ of +kind+ with none of its +items+ in Git. Only a type's
    # first kind is guarded: local roles are not, as a pod may well have none.
    # Cookbooks are told apart by dir, since there may be several.
    def self.empty_dirs(kind, items, dirs)
      return dirs - items.map { |item| item.change.cookbook_dir } if kind == :cookbooks

      items.empty? ? dirs : []
    end

    # Returns { kind => [Item] } for every kind of +types+ in +changeset+,
    # local roles only with +local_roles+; raises Knife::MismatchError via
    # Knife#check_uploads.
    def self.items_in_git(knife, changeset, local_roles, types)
      kinds = types.flat_map { |type| TYPES.fetch(type)[:kinds] }
      changes = kinds.to_h { |kind| [kind, kind == :roles_local && !local_roles ? [] : changeset.public_send(kind)] }
      knife.check_uploads(changes).to_h do |kind, ids|
        [kind, changes[kind].zip(ids).map { |change, id| GitState::Item.new(id: id, kind: kind, change: change) }]
      end
    end

    # Uploads everything +checks+ found missing, then deletes the extras of
    # each type its guard doesn't block. All uploads go first, so a failure
    # halfway leaves the server with too much rather than too little.
    #
    # Uploaded nodes are stamped with +rev+ and yielded right after their
    # upload, as in Diff.apply, so the caller can record them for
    # verification.
    def self.apply(knife, checks, rev, &on_nodes)
      checks.each { |check| upload_missing(knife, check, rev, &on_nodes) }
      checks.reject(&:blocked).each { |check| delete_extra(knife, check) }
    end

    def self.upload_missing(knife, check, rev)
      by_id = GitState.sources(check.items)
      check.drift.missing.map { |id| by_id.fetch(id) }.group_by(&:kind).each do |kind, items|
        changes = items.map(&:change)
        next knife.public_send(UPLOADERS.fetch(kind), changes) unless kind == :nodes

        knife.public_send(UPLOADERS.fetch(kind), changes, rev)
        yield changes
      end
    end

    def self.delete_extra(knife, check)
      type = TYPES.fetch(check.type)
      ref = type.fetch(:ref) { ->(id) { Knife::NameRef.new(*id) } }
      knife.public_send(type[:delete], check.drift.extra.map(&ref))
    end

    private_class_method :drift_lines, :summary, :label, :git_items, :built_in?, :empty_dirs, :items_in_git,
                         :upload_missing, :delete_extra
  end
end
