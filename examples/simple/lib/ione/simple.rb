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
      response = begin
        case message
        when 'π'
          Math::PI
        when 'τ'
          Math::PI * 2
        else
          {'error' => 'wat?'}
        end
      end
      Future.resolved(response)
    end
  end

  class SimpleClient < Ione::Rpc::Client
    def initialize(options={})
      super(Ione::Rpc::StandardCodec.new(JSON), options)
    end

    def pi
      send_request('π')
    end

    def tau
      send_request('τ')
    end
  end
end
