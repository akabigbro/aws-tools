Gem::Specification.new do |s|
  s.name        = 'aws-tools'
  s.version     = '0.0.2.1'
  s.date        = '2014-12-02'
  s.summary     = "A set of simple tools to bind some essential functions of aws resources"
  s.description = "A set of simple tools to bind some essential functions of aws resources"
  s.authors     = ["Kevin Connors"]
  s.email       = 'karmet@gmail.com'
  s.files       = ["lib/aws_region.rb"]
  s.homepage    =
    'http://rubygems.org/gems/aws-tools'
  s.license     = 'MIT'
  s.add_development_dependency "rspec"
  s.executables = 'aws_manager.rb'
end
