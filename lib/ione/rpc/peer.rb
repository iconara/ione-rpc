# encoding: utf-8

module Ione
  module Rpc
    class Peer
      attr_reader :host, :port

      def initialize(connection, protocol)
        @connection = connection
        @connection.on_data(&method(:handle_data))
        @connection.on_closed(&method(:handle_closed))
        @host = @connection.host
        @port = @connection.port
        @protocol = protocol
        @buffer = Ione::ByteBuffer.new
        @current_message = nil
      end

      protected

      def handle_data(new_data)
        @buffer << new_data
        while true
          @current_message, channel = @protocol.decode(@buffer, @current_message)
          break if @current_message.partial?
          handle_message(@current_message, channel)
          @current_message = nil
        end
      end

      def handle_message(message, channel)
      end

      def handle_closed(cause)
      end

      def send_message(message, channel)
        @connection.write(@protocol.encode(message, channel))
      end
    end
  end
end
