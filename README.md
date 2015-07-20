# Chef Delivery

## Intro

Welcome to Chef Delivery, software to keep cookbooks, clients, databags, environments, nodes, roles and users in
sync between a VCS repo and a chef server. The idea is that if you have
multiple, distinct Chef server instances that should all be identical or track a specific part of a Chef git repo, they can all run this script in cron. The script uses proper locking, so you should be
able to run it every minute.

Chef delivery is derived from Facebook's [Grocery Delivery](https://github.com/facebook/grocery-delivery) with the following changes:

 * Clients, environments, nodes and users can be tracked as well
 * Cookbook versioning can be used by version tag post pending cookbook dirs
 * Uses the Chef Server API so no knife config is needed
 * Only Git is supported

## Prerequisites

Chef Delivery is a particular way of managing your Chef infrastructure,
and it assumes you follow that model consistently. Here are the basic
principals:

* Checkins are live immediately (which implies code review before merge)
* You want all your Chef servers in sync with the Git repo
* A Chef server tracks all cookbook, user and role dirs
* A Chef server can track all node, client and environment dirs or just a subtree of these dirs (for segmenting infrastructure)
* Everything you care about comes from version control
* All files in the Chef repo must be JSON (except for cookbooks)

## Dependencies

* Mixlib::Config
* chef_diff

## Config file

The default config file is `/etc/chef/chef_delivery_config.rb` but you may use -c to specify
another. The config file works the same as client.rb does for Chef - there
are a series of keywords that take an argument and anything else is just
standard Ruby.

All command-line options are available in the config file:

* dry_run (bool, default: false)
* debug (bool, default: false)
* timestamp (bool, default: false)
* config_file (string, default: `/etc/chef/chef_delivery_config.rb`)
* lockfile (string, default: `/var/lock/chef_delivery`)
* pidfile (string, default: `/var/run/chef_delivery.pid`)

In addition the following are also available:

* master_path - The top-level path for Chef Delivery's work. Most other
  paths are relative to this. Default: `/var/chef/chef_delivery_work`
* repo_url - The URL to clone/checkout (git shallow clone) if it doesn't exist. Default: `nil`
* reponame - The relative directory to check the repo out to, inside of
  `master_path`. Default: `ops`
* pod_name - Name of subdir to match in environments, nodes and clients. Default: `nil` which means no filtering.
* user - username of the Chef uploader. Default: `admin`
* pem - Chef client key of the Chef uploader. . Default: `/etc/chef-server/admin.pem`
* chef_server_url - URL of the Chef server to upload to. Default: `https://127.0.0.1`
* client_path A directory to find clients in relative to `reponame`. Default:
  `clients`
* cookbook_paths - An array of directories that contain cookbooks relative to
  `reponame`. Default: `['cookbooks']`
* databag_path - A directory to find databags in relative to `reponame`.
  Default: `data_bags`
* environment_path - A directory to find environments in relative to `reponame`.
  Default: `environments`
* node_path - A directory to find nodes in relative to `reponame`. Default:
  `nodes`
* role_path - A directory to find roles in relative to `reponame`. Default:
  `roles`
* user_path - A directory to find users in relative to `reponame`. Default:
  `users`
* rev_checkpoint - Name of the file to store the last-uploaded revision,
  relative to `reponame`. Default: `chef_delivery_revision`
* plugin_path - Path to plugin file. Default: `/etc/chef_delivery_config_plugin.rb`

## Usage

The Chef Delivery script (chef-delivery) is designed to run on a Chef server as a cron job. The chef-delivery script pulls from the git chef-repo, determines which changes corresponds to Chef objects and upload the changed Chef objects.

For clients, nodes and environments chef-delivery can handle subdirs e.g.

	...
	|-- nodes
	|   |-- pod1
	|   |   |-- server1.pod1.mydomain.com
	|   |   |-- server2.pod1.mydomain.com
	|   |   `-- server3.pod1.mydomain.com
	|   `-- pod2
	|       |-- server1.pod2.mydomain.com
	|       `-- server2.pod2.mydomain.com
	...

so a specific Chef server can track just a subset of the chef-repo (using the pod_name config variable to specify which subdir) which can be used for segmenting infrastructure.

Cookbooks can either exists as unversioned or versioned. An unversioned cookbook is a normal cookbook in the cookbooks dir

	...
	|-- cookbooks
	|   |-- nginx
	|   `-- webthing
	...

any changes to a cookbook will be propagated by chef-delivery. It is recommended not to change the version tag in metadata.rb so the cookbook is overwritten on the Chef server as well.

A versioned cookbook can be kept by post pending a version tag to the cookbook name

	...
	|-- cookbooks
	|   ...
	|   |-- morewebthing-v1.5.6
	|   |-- morewebthing-v2.0.0
	|   `-- webthing
	...

In this case both versions of the 'morewebthing' cookbook will exist on the tracking Chef servers so environments can be used to lock down cookbook versions. Doing a 'git rm' of a versioned cookbook will also remove the cookbook version from the tracking Chef servers. The post pended version tag must be of the format 'v[major].[minor].[patch]' and match the version in metadata.rb.

## Chef server setup

Chef Delivery has been designed so the full configuration state is kept in the Chef repo and a Chef server can be bootstrapped to replace an existing Chef server quickly just by starting to track the Chef repo with Chef Delivery. Delegating Chef Server responsibility to pod level (subdir in clients, nodes and environments) can be accomplished by using Git sparse checkouts and the 'pod_name' variable of the Chef Delivery config file. Note: In order to use this scheme make sure your recipes do not rely on Chef searches which return empty result sets  (before the Chef clients have checked in) during bootstrapping of a new Chef server.
