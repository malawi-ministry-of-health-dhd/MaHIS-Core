# -*- encoding: utf-8 -*-
# stub: time_difference 0.5.0 ruby lib

Gem::Specification.new do |s|
  s.name = "time_difference".freeze
  s.version = "0.5.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["TM Lee".freeze]
  s.date = "2016-10-11"
  s.description = "TimeDifference is the missing Ruby method to calculate difference between two given time. You can do a Ruby time difference in year, month, week, day, hour, minute, and seconds.".freeze
  s.email = ["tmlee.ltm@gmail.com".freeze]
  s.homepage = "".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.4.1".freeze
  s.summary = "TimeDifference is the missing Ruby method to calculate difference between two given time. You can do a Ruby time difference in year, month, week, day, hour, minute, and seconds.".freeze

  s.installed_by_version = "3.4.1" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<activesupport>.freeze, [">= 0"])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 2.13.0"])
  s.add_development_dependency(%q<rake>.freeze, [">= 0"])
end
