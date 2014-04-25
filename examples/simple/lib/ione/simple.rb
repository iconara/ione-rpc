# encoding: utf-8

require 'ione/rpc'
require 'json'
require 'logger'


module Ione
  class SimpleServer < Ione::Rpc::Server
    def initialize(port, options={})
      super(port, JsonCodec.new, options)
    end

    def handle_message(message, *_)
      Future.resolved('hello' => 'world')
    end
  end

  class SimpleClient < Ione::Rpc::Client
    def initialize(options={})
      super(JsonCodec.new, options)
    end
  end

  class JsonCodec < Ione::Rpc::Codec
    def encode_message(message)
      JSON.dump(message)
    end

    def decode_message(str)
      JSON.load(str)
    end
  end
end
