# Running Sushi

## Intro

Welcome to Running Sushi, software to keep cookbooks, clients, databags, environments, nodes and roles in
sync between a Git repo and a Chef Server. The idea is that if you have
multiple, distinct Chef Server instances that should all be identical or track a specific part of a Chef Git repo, they can all run this script in cron. The script uses proper locking, so you should be
able to run it every minute.

Running Sushi is derived from Facebook's [Grocery Delivery](https://github.com/facebook/grocery-delivery) with the following changes:

 * Clients, environments and nodes can be tracked as well
 * Cookbook versioning can be used by version tag post pending cookbook dirs
 * It is possible to segment the repo in parts to be tracked by different Chef Servers (such a segment is termed "pod" in following documentation)
 * Uses the Chef Server API so no knife config is needed
 * Only Git is supported

**Note**: This project was previously named "Chef Delivery" but has been renamed to avoid confusion with the unrelated [Chef Delivery](https://www.chef.io/delivery/) project.

## Prerequisites

Running Sushi is a particular way of managing your Chef infrastructure,
and it assumes you follow that model consistently. Here are the basic
principals:

* Checkins are live immediately (which implies code review before merge)
* You want all your Chef Servers in sync with the Git repo
* A Chef Server tracks all cookbook, role and data bag dirs
* A Chef Server can track the node, client and environment dirs of every pod, or one pod of them including its local roles, see [Pods](#pods)
* Everything you care about comes from version control
* All files in the Chef repo must be JSON (except for cookbooks). It's recommended to use Git hooks to enforce this as Running Sushi aborts the Chef Server upload phase if invalid JSON is encountered.

## Why Running Sushi?

Running Sushi has been developed to address the following issues with the normal Chef workflow

* Human scaling: Managing using the Knife tool does not scale to many users. Enter a Git driven automatic workflow
* Infrastructure scaling: Running Sushi extends the Chef repo with a "pod" level allowing infrastructure described by a Chef repo to be segmented where each segment is controlled by a distinct Chef Server
* Disposability: Running Sushi demotes the Chef Server to a construction that tracks a Git repo. Thus a Chef Server can be destroyed and redeployed without any concerns

## Dependencies

* Ruby >= 3.0
* Chef and knife 17 to 19
* Mixlib::Config
* [chef_diff](https://github.com/One-com/chef_diff)

## Testing

```sh
docker run --rm -v "$(pwd)":/app -w /app ruby:3.4 \
  sh -c "bundle install && bundle exec rake"
```

Bundler picks the newest Chef that resolves on the given Ruby. To test one
Chef major, set `CHEF_VERSION` to it (e.g. `-e CHEF_VERSION=18`).

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
* reconcile (bool or list of types, default: false), see [Reconciling drift](#reconciling-drift)
* verbosity (Logger level, default: `Logger::WARN`); `-v` sets `Logger::INFO`,
  `-vv` `Logger::DEBUG`
* timestamp (bool, default: false); accepted, but has no effect
* config_file (string, default: `/etc/chef/running_sushi_config.rb`)
* lockfile (string, default: `/var/lock/running_sushi`)
* pidfile (string, default: `/var/run/running_sushi.pid`)

In addition the following are also available:

* master_path - The top-level path for Running Sushi's work. Most other
  paths are relative to this. Default: `/var/chef/running_sushi_work`
* repo_url - The URL to clone/checkout (Git shallow clone) if it doesn't exist. Default: `nil`
* reponame - The relative directory to check the repo out to, inside of
  `master_path`. Default: `ops`
* pod_name - Name of the pod to track: the subdir to match in nodes, clients,
  environments and roles_local, see [Pods](#pods). Default: `nil`, which tracks
  the nodes, clients and environments of every pod and ignores local roles.
* vcs_type - The version control system, `git` or `svn`. Default: `git`. Only
  `git` is tested, and sparse checkouts need `git`
* vcs_path - Path to the `vcs_type` binary. Default: `nil`, which uses `git` or
  `svn` from `PATH`
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
  `roles_local`. A local role in `<role_local_path>/<pod_name>/` overrides the
  global role of the same name. Without `pod_name` local roles are ignored and
  every role comes from `role_path`.
* rev_checkpoint - Name of the file to store the last-uploaded revision,
  relative to `master_path`. Default: `running_sushi_revision`
* node_checkpoint - Name of the file used to track nodes that need upload
  verification (guards against Chef client run race conditions). Relative to
  `master_path`. Default: `node_upload_checkpoint`
* ssl_verify_mode - SSL verification mode passed to the Chef API client.
  Default: `:verify_peer`
* plugin_path - Path to plugin file. Default: `/etc/running_sushi_plugin.rb`

## Usage

The Running Sushi script (**running-sushi**) is designed to run on a Chef Server as a cron job. The running-sushi script pulls from the Git chef-repo, determines which changes corresponds to Chef objects and upload the changed Chef objects.

Running Sushi logs to syslog (as `running-sushi`), and to stdout only when stdout is a terminal, so under cron it logs nothing to stdout (Chef library warnings and uncaught errors can still reach the terminal or cron mail). Warnings and errors are always logged; `verbosity` adds info and debug lines.

### Pods

The terms, precisely, since the directory layout alone does not tell them
apart:

* **Instance**: one running-sushi config (`/etc/chef/running_sushi_config.rb`
  or the file given with `-c`) and the cron entries that run it. It syncs into
  exactly one `chef_server_url`.
* **Namespace**: what `chef_server_url` points to, usually one Chef
  organization (`https://host/organizations/<org>`); a URL without
  `/organizations/`, like the default `https://127.0.0.1`, uses the server's
  default organization. Role, node, client and environment
  names are unique per organization, not per Chef Server host: one host with
  several organizations has several independent namespaces.
* **Pod**: the value of `pod_name` in one instance's config, and nothing
  else. A pod is a segment of the infrastructure; in the repo it is a subdir
  of that name under `nodes`, `clients`, `environments` and `roles_local`.
* **Virtual pod**: a pod whose `pod_name` is a path, such as `pod1/vpod1`. It
  is an ordinary pod in every respect: it needs its own instance and its own
  namespace. Nothing checks the namespace: two pods in one organization
  silently overwrite each other's objects of the same name, such as each
  pod's `production` environment, and a reconcile of `environments`, `nodes`
  or `clients` (or of `roles`, with local roles) deletes the other pod's
  objects as extra. "Virtual" only says it shares a parent dir (and typically a Chef Server
  host) with other pods.

Nothing in the repo marks a dir as a pod. `roles_local/pod1/vpod1/` is a
virtual pod only if some instance has `pod_name 'pod1/vpod1'`; if the
instances in use have `pod_name 'pod1'`, then `vpod1/` is a plain subdir that
only organizes the files of pod `pod1`, and its names share pod1's namespace
with every other subdir below `pod1/`. To know what a subdir is, read the
instances' configs, not the tree.

Rule of thumb: **one instance = one `pod_name` = one namespace**, and no two
instances share a namespace; nothing enforces either. Every file
an instance tracks lands in that one namespace, so two tracked files of one
type with one basename collide (see the name rule below). The fix for a collision is
either to rename one of them, or to split the files into separate pods: one
instance per subdir with `pod_name '<pod>/<subdir>'` and its own organization
as `chef_server_url`. Move any files directly in `<pod>/` into a subdir,
since they then reach no instance, and stop the `<pod>` instance (see the
virtual pod bullet below). A separate Chef Server host is not needed. Several
instances on one host also need their own `master_path`, since the checkout
and both checkpoints live under it. With a shared one, the instance that runs
second after a commit finds the revision checkpoint already at HEAD, so it
uploads nothing of that commit to its Chef Server: no cookbooks, roles or
data bags either. It also replaces the other instance's list of uploaded
nodes with its own, so the other never re-checks and re-uploads those nodes
after a chef-client run overwrote them. A shared `lockfile` only makes them
wait for each other.

A layout with two pods:

	...
	|-- environments
	|   |-- pod1
	|   |   `-- production.json
	|   `-- pod2
	|       `-- production.json
	|-- nodes
	|   |-- pod1
	|   |   |-- server1.pod1.mydomain.com.json
	|   |   `-- server2.pod1.mydomain.com.json
	|   `-- pod2
	|       `-- server1.pod2.mydomain.com.json
	|-- roles
	|   `-- web.json
	|-- roles_local
	|   `-- pod1
	|       `-- web.json
	...

* With `pod_name` set, a Chef Server tracks only `<dir>/<pod_name>/` of these
  four dirs, subdirs below it included. Everything else in them is invisible to
  it, top-level files too: an `environments/production.json` reaches no Chef
  Server that has a `pod_name`, so each pod needs its own copy.
* Without `pod_name`, the chef-repo is one global repo, not a set of pods: a
  Chef Server tracks `nodes`, `clients` and `environments` whole, and their
  subdirs only organize the files. So a node, client or environment name must
  be unique across the whole dir (see below); the tree above, with a
  `production.json` per pod, only works with `pod_name`. It ignores
  `roles_local`: one Chef role serves every node, so a pod's override would
  leak to the others. Every role comes from `roles`.
* A virtual pod `pod1/vpod1` tracks only `<dir>/pod1/vpod1/`. It does not
  inherit from its parent: a file directly in `roles_local/pod1/`, or in a
  sibling `roles_local/pod1/vpod2/`, never reaches it, so a local role
  shared by all virtual pods needs a copy in each, or a global role in
  `roles/` if every pod may have it. Conversely, an instance
  with `pod_name` `pod1` tracks `pod1/` whole, every virtual pod below it
  included: a node, client, environment or local role in more than one
  virtual pod is a duplicate name on it (see below). Don't run one next to
  instances for its virtual pods.
* Cookbooks, roles and data bags are not split by pod: every Chef Server
  tracks all of them.
* A local role overrides the global role of the same name, matched by name, so
  either side may use subdirs. In the tree above, the pod1 Chef Server neither
  uploads nor deletes role `web` when `roles/web.json` changes, since
  `roles_local/pod1/web.json` exists; deleting that local role uploads the
  global one in its place, or deletes the role when there is no global one.
  pod2 uses the global role.
* A Chef object is named after its file's basename, not its path:
  `nodes/pod1/a/web01.json` is the node `web01`. Within the tracked part of
  each of `nodes`, `clients`, `environments`, `roles`, and a pod's local roles,
  a name may have only one file, whatever subdir it's in. A Chef Server that
  tracks more than one pod or virtual pod needs the name to be unique across
  them. `nodes/a/web01.json` next to `nodes/b/web01.json` fails a run whose
  diff touches `web01`, or that re-uploads `web01` after its last upload
  failed verification, before anything is written, and the error names both
  files; a reconcile of that type fails too. A node and a client may share
  a name, since each type has its own.
* Moving a file to another subdir re-uploads the object from its new place;
  it is not deleted in between. An object is deleted only when the last file
  of its name is, and the delete looks it up by that file's name, not its
  path.

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

In this case both versions of the 'morewebthing' cookbook will exist on the tracking Chef Servers so environments can be used to lock down cookbook versions. Doing a 'git rm' of a versioned cookbook will also remove the cookbook version from the tracking Chef Servers. The post pended version tag must be of the format 'v[major].[minor].[patch]' and match the version in metadata.rb. Removing an unversioned cookbook removes every version of it from the tracking Chef Servers except those a cookbook directory in Git still provides, so renaming `webthing` to `webthing-v1.0.0`, or removing it next to `webthing-v0.9.0`, keeps the versioned ones.

Likewise, the `name` inside a role, environment, node or client JSON file, and the `id` inside a data bag item, must match its filename, and the `name` in a cookbook's metadata must match its directory name without the version tag; a directory in a cookbook path without a metadata file counts as a mismatch. (Metadata without a `name` fails the run too, with Chef's own invalid-metadata error.) Deletes look objects up by path, so an object uploaded under a different name could never be removed by deleting its file. Running Sushi therefore checks every file it is about to upload (and the name of every cookbook and the version of every versioned cookbook against its metadata) before it changes anything on the Chef Server. A changed global role that a local role overrides is checked too, although it is not uploaded, so every server fails on it alike. If one contradicts its path, the run fails without writing anything and without moving the checkpoint, naming each offending file; dry-run fails the same way. Later runs fail too until the file is fixed, then apply the whole backlog.

### Reconciling drift

A normal run only applies what changed in Git since the last run, so an object deleted or uploaded by hand with knife stays that way until its files change. With `-r`/`--reconcile` (config key `reconcile`), a successful run then compares every cookbook version, role (global, and local with `pod_name`), environment, node, client and data bag item in the checkout with the Chef Server, uploads what is missing and deletes what is extra. Only existence is compared: an object whose content was changed by hand is not detected.

`--reconcile=TYPES` limits a run to a comma-separated list of `cookbooks`, `roles`, `environments`, `nodes`, `clients` and `databags`, e.g. `--reconcile=cookbooks,nodes`; in the config file, `reconcile [:cookbooks, :nodes]`. Types left out are neither checked in Git nor listed on the server. An unknown type, or an empty list, exits with status 2 before the run starts. `-r` takes no list, so `-rn` still means `-r -n`.

* An extra cookbook version is deleted on its own, never the whole cookbook. That includes older versions of an unversioned cookbook left over from a version bump in `metadata.rb`. A version pin that only such a version satisfies (an environment's `cookbook_versions`, a metadata `depends`, a `recipe[name@version]` in a run list) breaks once it is deleted, so pin old versions through a versioned cookbook directory instead.
* A missing role is uploaded from `roles_local` when the file exists there, otherwise from `roles`. Without `pod_name` local roles don't count, so a role that only exists in `roles_local` is extra and deleted.
* The `_default` environment and the validator client (`chef-validator`, or `<org>-validator`) and `chef-webui` have no file in Git and are never deleted; a file in Git for one of them is ignored too, so reconcile never uploads it. Any other node or client without a file is, including one created by `knife bootstrap` and never committed.
* A missing node is uploaded stamped with the revision and verified on the next run, like a node from a normal run.
* A data bag left without items is deleted along with its last item. An empty data bag on the server is not counted as drift.
* A file whose name or version contradicts its path fails the reconcile before anything is compared or changed, the same rule as for a normal run. Reconcile checks every file in Git of the types it compares, not only changed ones, so it also fails on a mismatched file that never was part of a diff (e.g. one that a sparse-checkout or `cookbook_paths` change brought into scope).
* Reconcile only runs when the diff step succeeded and HEAD is the applied checkpoint, so a failed or partly applied run is never treated as drift. A dry run is the exception: since it neither updates the repo nor moves the checkpoint, HEAD can be ahead of the checkpoint (after a failed real run, a pull by hand, or on a Chef Server that has never run for real). It still reports then, with a warning that the report counts the unapplied commits as drift, so it lists everything a real run would change.
* Everything extra is deleted, however much that is. The one exception guards against a broken checkout (empty clone, wrong `cookbook_paths` or `role_path`, a sparse-checkout mistake): when one of the `cookbook_paths`, the `role_path`, or the (pod's) environment, node, client or data bag directory has nothing in Git, deletes of that type are refused and logged as an error naming the directory. Local roles don't count, since a pod may have none. Missing objects are still uploaded, and the other types are still reconciled. A configured cookbook path that is empty on purpose therefore blocks cookbook deletes until it is removed from `cookbook_paths`.

Every drift item is logged as a warning (`Reconcile: extra role foo`, `Reconcile: missing cookbook nginx 1.2.0`), followed by a summary line per type with counts. `-n --reconcile` logs the same report and changes nothing.

Reconcile lists every object on the server and holds the lock while it runs, so run it from its own, less frequent cron entry next to the per-minute one, e.g. hourly:

	0 * * * * /opt/chef/embedded/bin/running-sushi --reconcile

When rolling it out, start with `running-sushi -n --reconcile` and read the drift reports before dropping `-n`.

## Chef Server setup

Running Sushi has been designed so the full configuration state is kept in the Chef repo and a Chef Server can be bootstrapped to replace an existing Chef Server quickly just by starting to track the Chef repo with Running Sushi. Splitting the repo across Chef Servers is done with [pods](#pods). A Git sparse checkout is optional on top of it: files outside the sparse checkout count as not in Git, for normal runs and reconcile alike, so reconcile deletes their objects from the server. Running Sushi's own clone is a full shallow clone, so set up a sparse checkout yourself in `master_path`/`reponame` before the first run. Note: In order to use this scheme make sure your recipes do not rely on Chef searches which return empty result sets  (before the Chef clients have checked in) during bootstrapping of a new Chef Server.

## Cookbook dependency management

Running Sushi has no notion of cookbook dependencies and uploads all cookbooks in the Git repo to all tracking Chef Servers. Tools like [librarian-chef](https://github.com/applicationsonline/librarian-chef) can be used for cookbook development but the dependency cookbooks have to be added explicitly to Git repo.

## Limitations

* A node, client or environment name defined by two files is caught only by a run whose diff touches that name (see [Pods](#pods)), or by a reconcile of that type. A duplicate neither touches stays unreported; a Git hook that rejects two files of one basename within a Chef Server's tracked part of `nodes`, `clients` or `environments` catches it at push.
