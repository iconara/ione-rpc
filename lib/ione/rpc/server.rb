# encoding: utf-8

module Ione
  module Rpc
    class Server
      attr_reader :port

      def initialize(port, codec, options={})
        @port = port
        @codec = codec
        @io_reactor = options[:io_reactor] || Io::IoReactor.new
        @stop_reactor = !options[:io_reactor]
        @queue_length = options[:queue_size] || 5
        @bind_address = options[:bind_address] || '0.0.0.0'
      end

      def start
        @io_reactor.start.flat_map { setup_server }.map(self)
      end

      def stop
        @io_reactor.stop.map(self)
      end

      protected

      def handle_connection(peer)
      end

      def handle_message(message, peer)
        Future.resolved
      end

      private

      def setup_server
        @io_reactor.bind(@bind_address, @port, @queue_length) do |acceptor|
          acceptor.on_accept do |connection|
            handle_connection(ServerPeer.new(connection, @codec, self))
          end
        end
      end

      class ServerPeer < Peer
        def initialize(connection, codec, server)
          super(connection, codec)
          @server = server
        end

        def handle_message(message, channel)
          f = @server.handle_message(message, self)
          f.on_value do |response|
            write_message(response, channel)
          end
        end
      end
    end
  end
end
