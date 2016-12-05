# Running Sushi

## Intro

Welcome to Running Sushi, software to keep cookbooks, clients, databags, environments, nodes, roles and users in
sync between a Git repo and a Chef Server. The idea is that if you have
multiple, distinct Chef Server instances that should all be identical or track a specific part of a Chef Git repo, they can all run this script in cron. The script uses proper locking, so you should be
able to run it every minute.

Running Sushi is derived from Facebook's [Grocery Delivery](https://github.com/facebook/grocery-delivery) with the following changes:

 * Clients, environments, nodes and users can be tracked as well
 * Cookbook versioning can be used by version tag post pending cookbook dirs
 * It is possible to segment the repo in parts to be tracked by different Chef Servers (such a segment is termed "pod" in following documentation)
 * Uses the Chef Server API so no knife config is needed
 * Only Git is supported

**Note**: This project was previously named "Chef Delivery" but has been renamed to avoid confusion with the unrelated [Chef Delivery](https://www.chef.io/delivery/) project. Currently executable name and configuration still reflects the old project name.

## Prerequisites

Running Sushi is a particular way of managing your Chef infrastructure,
and it assumes you follow that model consistently. Here are the basic
principals:

* Checkins are live immediately (which implies code review before merge)
* You want all your Chef Servers in sync with the Git repo
* A Chef Server tracks all cookbook, user and role dirs
* A Chef Server can track all node, client and environment dirs or just a subtree of these dirs (for segmenting infrastructure). Roles can both be global and pod local
* Everything you care about comes from version control
* All files in the Chef repo must be JSON (except for cookbooks). It's recommended to use Git hooks to enforce this as Running Sushi aborts the Chef Server upload phase if invalid JSON is encountered.

## Why Running Sushi?

Running Sushi has been developed to address the following issues with the normal Chef workflow

* Human scaling: Managing using the Knife tool does not scale to many users. Enter a Git driven automatic workflow
* Infrastructure scaling: Running Sushi extends the Chef repo with a "pod" level allowing infrastructure described by a Chef repo to be segmented where each segment is controlled by a distinct Chef Server
* Disposability: Running Sushi demotes the Chef Server to a construction that tracks a Git repo. Thus a Chef Server can be destroyed and redeployed without any concerns

## Dependencies

* Mixlib::Config
* [chef_diff](https://github.com/One-com/chef_diff)

## Installation

Running Sushi uses the internal Chef API so it must be available on the installation host. It is recommended to install Running Sushi (and Chef Diff) on the Chef Server that should track a Chef repo:

    $ /opt/chef/embedded/bin/gem install /path/to/running_sushi-[version].gem

now Running Sushi can be executed as

    $ /opt/chef/embedded/bin/running-sushi -v

## Config file

The default config file is `/etc/chef/running_sushi_config.rb` but you may use -c to specify
another. The config file works the same as client.rb does for Chef - there
are a series of keywords that take an argument and anything else is just
standard Ruby.

All command-line options are available in the config file:

* dry_run (bool, default: false)
* debug (bool, default: false)
* timestamp (bool, default: false)
* config_file (string, default: `/etc/chef/running_sushi_config.rb`)
* lockfile (string, default: `/var/lock/running_sushi`)
* pidfile (string, default: `/var/run/running_sushi.pid`)

In addition the following are also available:

* master_path - The top-level path for Running Sushi's work. Most other
  paths are relative to this. Default: `/var/chef/running_sushi_work`
* repo_url - The URL to clone/checkout (Git shallow clone) if it doesn't exist. Default: `nil`
* reponame - The relative directory to check the repo out to, inside of
  `master_path`. Default: `ops`
* pod_name - Name of subdir to match in environments, nodes and clients. Default: `nil` which means no filtering.
* user - username of the Chef uploader. Default: `admin`
* pem - Chef client key of the Chef uploader. . Default: `/etc/chef-server/admin.pem`
* chef\_server\_url - URL of the Chef Server to upload to. Default: `https://127.0.0.1`
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
* role\_local\_path - A directory to find pod specific roles in relative to `reponame`. Default:
  `roles_local`
* user_path - A directory to find users in relative to `reponame`. Default:
  `users`
* rev_checkpoint - Name of the file to store the last-uploaded revision,
  relative to `reponame`. Default: `running_sushi_revision`
* plugin_path - Path to plugin file. Default: `/etc/running_sushi_config_plugin.rb`

## Usage

The Running Sushi script (**running-sushi**) is designed to run on a Chef Server as a cron job. The running-sushi script pulls from the Git chef-repo, determines which changes corresponds to Chef objects and upload the changed Chef objects.

For clients, nodes, environments and roles_local running-sushi can handle subdirs e.g.

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

so a specific Chef Server can track just a subset of the chef-repo (using the pod_name config variable to specify which subdir) which can be used for segmenting infrastructure.

Cookbooks can either exists as unversioned or versioned. An unversioned cookbook is a normal cookbook in the cookbooks dir

	...
	|-- cookbooks
	|   |-- nginx
	|   `-- webthing
	...

any changes to a cookbook will be propagated by running-sushi. It is recommended not to change the version tag in metadata.rb so the cookbook is overwritten on the Chef Server as well.

A versioned cookbook can be kept by post pending a version tag to the cookbook name

	...
	|-- cookbooks
	|   ...
	|   |-- morewebthing-v1.5.6
	|   |-- morewebthing-v2.0.0
	|   `-- webthing
	...

In this case both versions of the 'morewebthing' cookbook will exist on the tracking Chef Servers so environments can be used to lock down cookbook versions. Doing a 'git rm' of a versioned cookbook will also remove the cookbook version from the tracking Chef Servers. The post pended version tag must be of the format 'v[major].[minor].[patch]' and match the version in metadata.rb.

## Chef Server setup

Running Sushi has been designed so the full configuration state is kept in the Chef repo and a Chef Server can be bootstrapped to replace an existing Chef Server quickly just by starting to track the Chef repo with Running Sushi. Delegating Chef Server responsibility to pod level (subdir in clients, nodes, environments and roles\_local) can be accomplished by using Git sparse checkouts and the 'pod_name' variable of the Running Sushi config file. Note: In order to use this scheme make sure your recipes do not rely on Chef searches which return empty result sets  (before the Chef clients have checked in) during bootstrapping of a new Chef Server.

## Cookbook dependency management

Running Sushi has no notion of cookbook dependencies and uploads all cookbooks in the Git repo to all tracking Chef Servers. Tools like [librarian-chef](https://github.com/applicationsonline/librarian-chef) can be used for cookbook development but the dependency cookbooks have to be added explicitly to Git repo.

## Limitations

* Running Sushi does not check if two (node, environment, role) names are the same but the .json files are different. This should be controlled with Git hooks or similar
* Currently Running Sushi only supports Chef Server 11 as Chef Server 12 has introduced breaking changes with regards to node preseeding
