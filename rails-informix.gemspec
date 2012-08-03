
spec = Gem::Specification.new do |s|
  s.name = 'activerecord-informix-adapter'
  s.summary = 'Informix adapter for Active Record'
  s.description = 'Active Record adapter for connecting to an IBM Informix database'
  s.version = '2.0.0'

  s.add_dependency 'activerecord', '>= 3.2.0'
  s.add_dependency 'ruby-informix', '>= 0.7.3'
  s.require_path = 'lib'

  s.files = %w(lib/active_record/connection_adapters/informix_adapter.rb)

  s.author = 'Gerardo Santana Gomez Garrido, Martin Little'
  s.email = 'khronos@tempusfactor.com'
  s.homepage = 'http://rails-informix.rubyforge.org/'
  s.rubyforge_project = 'rails-informix'
end
