$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "spree_paypal_wps/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "spree_paypal_wps"
  s.version     = SpreePaypalWps::VERSION
  s.authors     = ["Rui Leitão"]
  s.email       = ["rmleitao@thinkorange.pt"]
  s.homepage    = "https://github.com/rmleitao/spree_paypal_wps"
  s.summary     = "Spree support for PayPal Website Payments Standard."
  s.description = "Spree support for PayPal Website Payments Standard, with subscription management."
  s.required_ruby_version = '>= 1.9.2'

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 4.0.3"
  s.add_dependency 'spree_core', '~> 2.1.4.beta'

  s.add_development_dependency "sqlite3"
end
