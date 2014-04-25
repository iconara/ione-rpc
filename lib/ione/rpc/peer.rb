# encoding: utf-8

module Ione
  module Rpc
    # @private
    class Peer
      attr_reader :host, :port

      def initialize(connection, codec)
        @connection = connection
        @connection.on_data(&method(:handle_data))
        @connection.on_closed(&method(:handle_closed))
        @host = @connection.host
        @port = @connection.port
        @codec = codec
        @buffer = Ione::ByteBuffer.new
        @closed_promise = Promise.new
        @current_message = nil
      end

      def on_closed(&listener)
        @closed_promise.future.on_value(&listener)
      end

      protected

      def handle_data(new_data)
        @buffer << new_data
        while true
          @current_message, channel, complete = @codec.decode(@buffer, @current_message)
          break unless complete
          handle_message(@current_message, channel)
          @current_message = nil
        end
      end

      def handle_message(message, channel)
      end

      def handle_closed(cause=nil)
        @closed_promise.fulfill(cause)
      end

      def write_message(message, channel)
        @connection.write(@codec.encode(message, channel))
      end
    end
  end
end
