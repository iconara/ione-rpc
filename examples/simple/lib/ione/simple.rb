# encoding: utf-8

require 'ione/rpc'
require 'json'
require 'logger'


module Ione
  class SimpleServer < Ione::Rpc::Server
    def initialize(port, options={})
      super(port, Ione::Rpc::StandardCodec.new(JSON), options)
    end

    def handle_message(message, *_)
      Future.resolved('hello' => 'world')
    end
  end

  class SimpleClient < Ione::Rpc::Client
    def initialize(options={})
      super(Ione::Rpc::StandardCodec.new(JSON), options)
    end
  end
end
