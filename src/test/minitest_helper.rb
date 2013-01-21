ENV["RAILS_ENV"] = "test"

require File.expand_path('../../config/environment', __FILE__)
require 'minitest/autorun'
require 'minitest/rails'
require 'json'


class MiniTest::Rails::ActiveSupport::TestCase
  include FactoryGirl::Syntax::Methods

  self.use_transactional_fixtures = true
  self.use_instantiated_fixtures = false
  self.pre_loaded_fixtures = true
  self.fixture_path = File.expand_path('../fixtures/models', __FILE__)
  self.set_fixture_class :environments => KTEnvironment
end

def configure_vcr
  require "vcr"

  mode = ENV['mode'] ? ENV['mode'] : :none

  VCR.configure do |c|
    c.cassette_library_dir = 'test/fixtures/vcr_cassettes'
    c.hook_into :webmock
    c.default_cassette_options = {
      :record => mode.to_sym,
      :match_requests_on => [:method, :path, :params],
      :serialize_with => :syck
    }

    begin
      c.register_request_matcher :body_json do |request_1, request_2|
        begin
          json_1 = JSON.parse(request_1.body) 
          json_2 = JSON.parse(request_2.body)

          json_1 == json_2
        rescue
          #fallback incase there is a JSON parse error
          request_1.body == request_2.body
        end
      end
    rescue => e
      #ignore the warning thrown about this matcher already being resgistered
    end

    begin
      c.register_request_matcher :params do |request_1, request_2|
        URI(request_1.uri).query == URI(request_2.uri).query
      end
    rescue => e
      #ignore the warning thrown about this matcher already being resgistered
    end

  end
end

def configure_runcible
  uri = URI.parse(AppConfig.pulp.url)

  Runcible::Base.config = { 
    :url      => "#{uri.scheme}://#{uri.host}",
    :api_path => uri.path,
    :user     => "admin",
    :oauth    => {:oauth_secret => AppConfig.pulp.oauth_secret,
                  :oauth_key    => AppConfig.pulp.oauth_key }
  }

  Runcible::Base.config[:logger] = 'stdout' if ENV['logging'] == "true"
end

def disable_glue_layers(services=[], models=[])
  @@model_service_cache ||= {}
  change = false

  AppConfig.use_cp            = services.include?('Candlepin') ? false : true
  AppConfig.use_pulp          = services.include?('Pulp') ? false : true
  AppConfig.use_foreman       = services.include?('Foreman') ? false : true
  AppConfig.use_elasticsearch = services.include?('ElasticSearch') ? false : true

  cached_entry = {:cp=>AppConfig.use_cp, :pulp=>AppConfig.use_pulp, :es=>AppConfig.use_elasticsearch, :foreman => AppConfig.use_foreman}
  models.each do |model|
    if @@model_service_cache[model] != cached_entry
      Object.send(:remove_const, model)
      load "app/models/#{model.underscore}.rb"
      @@model_service_cache[model] = cached_entry
      change = true
    end
  end

  if change
    ActiveSupport::Dependencies::Reference.clear!
    FactoryGirl.reload
  end
end


class ResourceTypeBackup
  @@types_backup = ResourceType::TYPES.clone

  def self.restore
    ResourceType::TYPES.clear
    ResourceType::TYPES.merge!(@@types_backup)
  end
end


class CustomMiniTestRunner
  class Unit < MiniTest::Unit

    def before_suites
      # code to run before the first test
      configure_vcr
    end

    def after_suites
      # code to run after the last test
    end

    def _run_suites(suites, type)
      begin
        if ENV['suite']
          suites = suites.select do |suite|
                     suite.name == ENV['suite']
                   end
        end

        before_suites
        super(suites, type)
      ensure
        after_suites
      end
    end

    def _run_suite(suite, type)
      begin
        User.current = nil  #reset User.current
        suite.before_suite if suite.respond_to?(:before_suite)
        super(suite, type)
      ensure
        suite.after_suite if suite.respond_to?(:after_suite)
        ResourceTypeBackup.restore
      end
    end

  end
end

MiniTest::Unit.runner = CustomMiniTestRunner::Unit.new