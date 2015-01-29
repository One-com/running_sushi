Gem::Specification.new do |s|
  s.name = 'chef_delivery'
  s.version = '0.2.1'
  s.platform = Gem::Platform::RUBY
  s.summary = 'Chef Delivery'
  s.description = 'Utility for keeping Chef servers in sync with a repo'
  s.authors = ['Esben S. Nielsen']
  s.extra_rdoc_files = ['README.md', 'LICENSE']
  s.files = %w{README.md LICENSE} + Dir.glob("lib/chef_delivery/*.rb") +
    Dir.glob("bin/*")
  s.executables = 'chef-delivery'
  s.license = 'Apache'
  %w{
    mixlib-config
    chef_diff
  }.each do |dep|
    s.add_dependency dep
  end
end
