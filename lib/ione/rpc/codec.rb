# encoding: utf-8

module Ione
  module Rpc
    class Codec
      def encode(message, channel)
        data = encode_message(message)
        [1, channel, data.bytesize, data].pack('ccNa*')
      end

      def decode(buffer, state)
        state ||= State.new(buffer)
        if state.header_ready?
          state.read_header
        end
        if state.body_ready?
          return decode_message(state.read_body), state.channel, true
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
          n = @buffer.read_short
          @version = n >> 8
          @channel = n & 0xff
          @length = @buffer.read_int
        end

        def read_body
          @buffer.read(@length)
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
end