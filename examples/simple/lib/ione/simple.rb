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

  class JsonCodec
    def encode(message, channel)
      json = JSON.dump(message)
      [json.bytesize, channel, json].pack('Nca*')
    end

    def decode(buffer, state)
      state ||= State.new(buffer)
      if state.header_ready?
        state.read_header
      end
      if state.body_ready?
        return state.read_body, state.channel, true
      else
        return state, nil, false
      end
    end

    class State
      attr_reader :channel

      def initialize(buffer)
        @buffer = buffer
      end

      def read_header
        @length = @buffer.read_int
        @channel = @buffer.read_byte
      end

      def read_body
        JSON.load(@buffer.read(@length))
      end

      def <<(data)
        @buffer << data
      end

      def header_ready?
        @length.nil? && @buffer.size >= 5
      end

      def body_ready?
        @length && @buffer.size >= @length
      end

      def partial?
        @body.nil?
      end
    end
  end
end
