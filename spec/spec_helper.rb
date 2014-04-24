# encoding: utf-8

ENV['SERVER_HOST'] ||= '127.0.0.1'.freeze

require 'bundler/setup'

unless ENV['COVERAGE'] == 'no' || RUBY_ENGINE == 'rbx'
  require 'coveralls'
  require 'simplecov'

  if ENV.include?('TRAVIS')
    Coveralls.wear!
    SimpleCov.formatter = Coveralls::SimpleCov::Formatter
  end

  SimpleCov.start do
    add_group 'Source', 'lib'
    add_group 'Unit tests', 'spec/ione'
    add_group 'Integration tests', 'spec/integration'
  end
end

require 'ione/rpc'
