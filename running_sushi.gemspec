# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = 'running_sushi'
  s.version = '0.7.2'
  s.platform = Gem::Platform::RUBY
  s.summary = 'Running Sushi'
  s.description = 'Utility for keeping Chef servers in sync with a repo'
  s.authors = ['Esben S. Nielsen']
  s.homepage = 'https://github.com/One-com/running_sushi'
  s.metadata = {
    'source_code_uri' => 'https://github.com/One-com/running_sushi',
    'bug_tracker_uri' => 'https://github.com/One-com/running_sushi/issues',
    'rubygems_mfa_required' => 'true'
  }
  s.extra_rdoc_files = ['README.md', 'LICENSE']
  s.files = %w[README.md LICENSE] + Dir.glob('lib/running_sushi/*.rb') +
            Dir.glob('bin/*')
  s.executables = 'running-sushi'
  s.license = 'Apache-2.0'
  s.required_ruby_version = '>= 2.7'
  s.add_dependency 'chef', '>= 16'
  s.add_dependency 'chef_diff'
  s.add_dependency 'knife', '>= 16', '< 19'
  s.add_dependency 'mixlib-config'
  s.add_development_dependency 'chef-zero'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'rubocop'
  s.add_development_dependency 'simplecov'
end
