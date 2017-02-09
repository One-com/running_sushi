Gem::Specification.new do |s|
  s.name = 'running_sushi'
  s.version = '0.7.0'
  s.platform = Gem::Platform::RUBY
  s.summary = 'Running Sushi'
  s.description = 'Utility for keeping Chef servers in sync with a repo'
  s.authors = ['Esben S. Nielsen']
  s.extra_rdoc_files = ['README.md', 'LICENSE']
  s.files = %w{README.md LICENSE} + Dir.glob("lib/running_sushi/*.rb") +
    Dir.glob("bin/*")
  s.executables = 'running-sushi'
  s.license = 'Apache'
  %w{
    mixlib-config
    chef_diff
  }.each do |dep|
    s.add_dependency dep
  end
end
