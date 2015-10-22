# encoding: utf-8

module Ione
  module Rpc
    # This is the base class of server peers.
    #
    # To implement a server you need to create a subclass of this class and
    # implement {#handle_request}. You can also optionally implement
    # {#handle_connection} to do initialization when a new client connects, and
    # {#handle_error} to handle errors that occur during the request handling.
    class Server
      attr_reader :port

      def initialize(port, codec, options={})
        @port = port
        @codec = codec
        @io_reactor = options[:io_reactor] || Io::IoReactor.new
        @stop_reactor = !options[:io_reactor]
        @queue_length = options[:queue_size] || 5
        @bind_address = options[:bind_address] || '0.0.0.0'
        @logger = options[:logger]
      end

      # Start listening for client connections. This also starts the IO reactor
      # if it was not already started.
      #
      # The returned future resolves when the server is ready to accept
      # connections, or fails if there is an error starting the server.
      #
      # @return [Ione::Future<Ione::Rpc::Server>] a future that resolves to the
      #   server when all hosts have been connected to.
      def start
        @io_reactor.start.flat_map { setup_server }.map(self)
      end

      # Stop the server and close all connections. This also stops the IO reactor
      # if it has not already stopped.
      #
      # @return [Ione::Future<Ione::Rpc::Server>] a future that resolves to the
      #   server when all connections have closed and the IO reactor has stopped.
      def stop
        @io_reactor.stop.map(self)
      end

      # Override this method to do work when a new client connects.
      #
      # This method may be called concurrently.
      #
      # @return [nil] the return value of this method is ignored
      def handle_connection(connection)
      end

      # Override this method to handle errors raised or returned by
      # {#handle_request} or any other part of the request handling (for example
      # the response encoding).
      #
      # When this method raises an error or returns a failed future there will be
      # no response for the request. Unless you use a custom client this means
      # that you lock up one of the connection's channels forever, and depending
      # on the client implementation it may lock up resources. Make sure that
      # you always return a future that will resolve to something that will be
      # encodeable.
      #
      # Should this method fail a message will be logged at the `error` level
      # with the error message and class. The full backtrace will also be logged
      # at the `debug` level.
      #
      # @return [Ione::Future<Object>] a future that will resolve to an alternate
      #   response for this request.
      def handle_error(error, request, connection)
        Ione::Future.failed(error)
      end

      # Override this method to handle requests.
      #
      # You must respond to all requests, otherwise the client will eventually
      # use up all of its channels and not be able to send any more requests.
      #
      # This method may be called concurrently.
      #
      # When this method raises an error, or returns a failed future, {#handle_error}
      # will be called with the error.
      #
      # @param [Object] message a (decoded) message from a client
      # @param [#host, #port, #on_closed] connection the client connection that
      #   received the message
      # @return [Ione::Future<Object>] a future that will resolve to the response.
      def handle_request(message, connection)
        Future.resolved
      end

      # @private
      def guarded_handle_error(error, request, connection)
        handle_error(error, request, connection)
      rescue => e
        Ione::Future.failed(e)
      end

      # @private
      def guarded_handle_request(message, connection)
        handle_request(message, connection)
      rescue => e
        Ione::Future.failed(e)
      end

      private

      def setup_server
        @io_reactor.bind(@bind_address, @port, @queue_length) do |acceptor|
          @acceptor = acceptor
          @logger.info('Server listening for connections on %s:%d' % [@bind_address, @port]) if @logger
          @acceptor.on_accept do |connection|
            @logger.info('Connection from %s:%d accepted' % [connection.host, connection.port]) if @logger
            peer = ServerPeer.new(connection, @codec, self, @logger)
            if @logger
              peer.on_closed do |error|
                if error
                  @logger.warn(sprintf('Connection from %s:%d closed unexpectedly: %s (%s)', connection.host, connection.port, error.message, error.class.name))
                else
                  @logger.info(sprintf('Connection from %s:%d closed', connection.host, connection.port))
                end
              end
            end
            handle_connection(peer)
          end
        end
      end

      # @private
      class ServerPeer < Peer
        def initialize(connection, codec, server, logger)
          super(connection, codec)
          @server = server
          @logger = logger
        end

        def handle_message(message, channel)
          f = @server.guarded_handle_request(message, self)
          send_response(f, message, channel, true)
        end

        def send_response(f, message, channel, try_again)
          f = f.map do |response|
            encoded_response = @codec.encode(response, channel)
            @connection.write(encoded_response)
            nil
          end
          f.fallback do |error|
            if try_again
              ff = @server.guarded_handle_error(error, message, self)
              send_response(ff, message, channel, false)
            else
              @logger.error('Unhandled error: %s (%s)' % [error.message, error.class.name])
              error.backtrace && @logger.debug(error.backtrace.join("#{$/}\t"))
            end
          end
        end
      end
    end
  end
end
