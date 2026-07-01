# frozen_string_literal: true

# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop:2:tabstop=2

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

# Shared test helpers for the Running Sushi minimal test suite.
#
# The suite intentionally avoids mocking/stubbing: anything that needs Chef,
# Mixlib::Config etc. is pulled in for real. Tests stick to pure logic so
# the network/file-system/Chef-Server side effects are never exercised.

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

ROOT_DIR = File.expand_path('..', __dir__)
BIN_PATH = File.join(ROOT_DIR, 'bin', 'running-sushi')

# ── Fake change structs (mirror the ChefDiff::Changes shapes) ────────────────

# Mimics ChefDiff::Changes::Change — upload_standard uses full_name for the
# filename, delete_standard uses name for the server-side lookup.
Change = Struct.new(:full_name, :name)

# Mimics ChefDiff::Changes::Databag — needs name (bag) and item.
DatabagChange = Struct.new(:name, :item, :full_name)

# Mimics ChefDiff::Changes::Cookbook — needs name (dir) and cookbook_dir.
CookbookChange = Struct.new(:name, :cookbook_dir)

def make_change(name)
  Change.new(name, name)
end

def databag_change(bag, item)
  DatabagChange.new(bag, item, "#{bag}/#{item}")
end

def cookbook_change(dir_name, cookbook_dir = 'cookbooks')
  CookbookChange.new(dir_name, cookbook_dir)
end

# Pull bin/running-sushi into the test process so its top-level helper methods
# and ChangeProxy are defined, WITHOUT running the real entry point. The no-op
# singleton `main` shadows the bottom-of-file `main` call at load time only;
# the real Object#main remains callable from examples (see spec for `main`).
define_singleton_method(:main) { nil } unless respond_to?(:main)
load BIN_PATH
