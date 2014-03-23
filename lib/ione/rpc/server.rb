# encoding: utf-8

module Ione
  module Rpc
    class Server
      attr_reader :port

      def initialize(server_handler_factory, port, options={})
        @port = port
        @server_handler_factory = server_handler_factory
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

      private

      def setup_server
        @io_reactor.bind(@bind_address, @port, @queue_length) do |acceptor|
          acceptor.on_accept do |connection|
            @server_handler_factory.call(connection)
          end
        end
      end
    end
  end
end
