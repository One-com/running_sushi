# Chef Delivery

## Intro

Welcome to Chef Delivery, software to keep cookbooks, clients, databags, environments, nodes, roles and users in
sync between a VCS repo and a chef server. The idea is that if you have
multiple, distinct Chef server instances that should all be identical or track a specific part of a Chef git repo, they can all run this script in cron. The script uses proper locking, so you should be
able to run it every minute.

Chef delivery is derived from Facebook's Grocery with the following changes:

 * Clients, environments, nodes and users can be tracked as well
 * Cookbook versioning can be used by version tag postpending cookbook dirs
 * Uses the Chef server API so no knife config is needed

Chef Delivery is pretty customizable. Many things can be tuned from a simple
config file, and it's pluggable so you can extend it as well.

## Prerequisites

Chef Delivery is a particular way of managing your Chef infrastructure,
and it assumes you follow that model consistently. Here are the basic
principals:

* Checkins are live immediately (which implies code review before merge)
* You want all your chef-servers in sync
* Everything you care about comes from version control.

## Dependencies

* Mixlib::Config
* ChefDiff

## Config file

The default config file is `/etc/gd-config.rb` but you may use -c to specify
another. The config file works the same as client.rb does for Chef - there
are a series of keywords that take an arguement and anything else is just
standard Ruby.

All command-line options are available in the config file:
* dry_run (bool, default: false)
* debug (bool, default: false)
* timestamp (bool, default: false)
* config_file (string, default: `/etc/chef_delivery_config.rb`)
* lockfile (string, default: `/var/lock/subsys/chef_delivery`)
* pidfile (string, default: `/var/run/chef_delivery.pid`)

In addition the following are also available:
* master_path - The top-level path for Chef Delivery's work. Most other
  paths are relative to this. Default: `/var/chef/chef_delivery_work`
* repo_url - The URL to clone/checkout if it doesn't exist. Default: `nil`
* reponame - The relative directory to check the repo out to, inside of
  `master_path`. Default: `ops`
* user - username of the Chef uploader. Default: `admin`
* pem - Chef client key of the Chef uploader. . Default: `/etc/chef-server/admin.pem`
* chef_server_url - URL of the Chef server to upload to. Default: `https://127.0.0.1`
* cookbook_paths - An array of directories that contain cookbooks relative to
  `reponame`. Default: `['cookbooks']`
* role_path - A directory to find roles in relative to `reponame`. Default:
  `['roles']`
* databag_path - A directory to find databags in relative to `reponame`.
  Default: `['databags']`
* rev_checkpoint - Name of the file to store the last-uploaded revision,
  relative to `reponame`. Default: `chef_delivery_revision`
* vcs_type - Git or SVN? Default: `git`
* vcs_path - Path to git or svn binary. If not given, just uses 'git' or 'svn'.
  Default: `nil`
* plugin_path - Path to plugin file. Default: `/etc/chef_delivery_config_plugin.rb`

## Plugin

The plugin should be a ruby file which defines several class methods. It is
class_eval()d into a Hooks class.

The following functions can optionally be defined:

* self.preflight_checks(dryrun)

This code will run once we've read our config and loaded our plugins but before
*anything* else. We don't even have a lock yet. `Dryrun` is a bool which
indicates if we are in dryrun mode.

* self.prerun(dryrun)

This is run after we've gotten a lock, written a pidfile and initialized our
repo object (but not touched the repo yet)

* self.post_repo_up(dryrun)

This is code to run after we've updated the repo, but before we've done any work
to parse it.

* self.postrun(dryrun, success, msg)

After we've parsed the updates to the repo and uploaded/deleted the relevent
items from the local server. `Success` is a bool for whether we succeeded, and
`msg` is the status message - either the revision we sync'd or an error.

* self.atexit(dryrun, success, msg)

Same as postrun, but is registered as an atexit function so it happens even
if we crash.
