# encoding: utf-8

module Ione
  module Rpc
    # This is the base class of client peers.
    #
    # You can either create a subclass and add your own high-level convenience
    # methods for constructing and sending your custom requests, or you can
    # create a standalone client object and call {#send_request}.
    #
    # A subclass may optionally implement {#initialize_connection} to send a
    # message immediately on a successful connection, and {#choose_connection}
    # to decide which connection to use for a request.
    #
    # The client will handle connections to multiple server peers, and
    # automatically reconnect to them when they disconnect.
    class Client
      # Create a new client with the specified codec and options.
      #
      # @param [Object] codec the protocol codec to use to encode requests and
      #   decode responses. See {Ione::Rpc::Codec}.
      # @param [Hash] options
      # @option options [Array<String>] :hosts the host (and ports) to connect
      #   to, specified either as an array of host (String) and port (Integer)
      #   pairs (e.g. `[['host1', 1111], [`host2`, 2222]]`) or an array of
      #   strings on the format host:port (e.g. `['host1:1111', 'host2:2222']`).
      # @option options [Ione::Io::IoReactor] :io_reactor use this option to
      #   make the client use an existing IO reactor and not create its own.
      #   Please note that {#stop} will still stop the reactor.
      # @option options [Integer] :connection_timeout (5) the number of seconds
      #   to wait for connections to be established before failing.
      # @option options [Integer] :max_channels (128) the maximum number of
      #   channels supported for each connection.
      # @option options [Logger] :logger a logger conforming to the standard
      #   Ruby logger API that will be used to log significant events like
      #   request failures.
      def initialize(codec, options={})
        @codec = codec
        @lock = Mutex.new
        @connection_timeout = options[:connection_timeout] || 5
        @io_reactor = options[:io_reactor] || Io::IoReactor.new
        @max_channels = options[:max_channels] || 128
        @logger = options[:logger]
        @hosts = []
        @connections = []
        Array(options[:hosts]).each { |h| add_host(*h) }
      end

      # A client is connected when it has at least one open connection.
      def connected?
        @lock.lock
        @connections.any?
      ensure
        @lock.unlock
      end

      # Start the client and connect to all hosts. This also starts the IO
      # reactor if it was not already started.
      #
      # The returned future resolves when all hosts have been connected to, and
      # if one or more fails to connect the client will periodically try again,
      # and the future will not resolve until all of them have connected.
      #
      # @return [Ione::Future<Ione::Rpc::Client>] a future that resolves to the
      #   client when all hosts have been connected to.
      def start
        @io_reactor.start.flat_map { connect_all }.map(self)
      end

      # Stop the client and close all connections. This also stops the IO
      # reactor if it has not already stopped.
      #
      # @return [Ione::Future<Ione::Rpc::Client>] a future that resolves to the
      #   client when all connections have closed and the IO reactor has stopped.
      def stop
        @lock.synchronize { @connections = [] }
        @io_reactor.stop.map(self)
      end

      # Add an additional host to connect to. This can be done either before
      # or after the client is started.
      #
      # @param [String] hostname the host to connect to, or the host:port pair (in
      #   which case the port parameter should be `nil`).
      # @param [Integer] port the host to connect to, or `nil` if the host is
      #   a string on the format host:port.
      # @return [Ione::Future<Ione::Rpc::Client>] a future that resolves to the
      #   client when the host has been connected to.
      def add_host(hostname, port=nil)
        hostname, port = normalize_address(hostname, port)
        promise = nil
        @lock.synchronize do
          _, _, promise = @hosts.find { |h, p, _| h == hostname && p == port }
          if promise
            return promise.future
          else
            promise = Promise.new
            @hosts << [hostname, port, promise]
          end
        end
        if @io_reactor.running?
          promise.observe(connect(hostname, port))
        end
        promise.future.map(self)
      end

      # Remove a host and disconnect any connections to it. This can be done
      # either before or after the client is started.
      #
      # @param [String] hostname the host to connect to, or the host:port pair (in
      #   which case the port parameter should be `nil`).
      # @param [Integer] port the host to connect to, or `nil` if the host is
      #   a string on the format host:port.
      # @return [Ione::Future<Ione::Rpc::Client] a future that resolves to the
      #   client (immediately, this is mostly to be consistent with #add_host)
      def remove_host(hostname, port=nil)
        hostname, port = normalize_address(hostname, port)
        @lock.synchronize do
          index = @hosts.index { |h, p, _| h == hostname && p == port }
          if index
            @hosts.delete_at(index)
            if (connection = @connections.find { |c| c.host == hostname && c.port == port })
              connection.close
            end
          end
        end
        Future.resolved(self)
      end

      # Send a request to a server peer. The peer chosen is determined by the
      # Implementation of {#choose_connection}, which is random selection by
      # default.
      #
      # If a connection closes between the point where it was chosen and when
      # the message was written to it, the request is retried on another
      # connection. For all other errors the request is not retried and it is
      # up to the caller to determine if the request is safe to retry.
      #
      # If a logger has been specified the following will be logged:
      # * A warning when a connection has closed and the request will be retried
      # * A warning when a request fails for another reason
      # * A warning when there are no open connections
      #
      # @param [Object] request the request to send.
      # @param [Object] connection the connection to send the request on. This
      #   parameter is internal and should only be used from {#initialize_connection}.
      # @param [Object] timeout the maximum time in seconds to wait for a response
      #   before failing the returned future with a {Ione::Rpc::TimeoutError}.
      #   There is no timeout by default.
      # @return [Ione::Future<Object>] a future that resolves to the response
      #   from the server, or fails because there was an error while processing
      #   the request (this is not the same thing as the server sending an
      #   error response – that is protocol specific and up to the implementation
      #   to handle), or when there was no connection open.
      def send_request(request, connection=nil, timeout=nil)
        unless connection
          @lock.lock
          begin
            connection = choose_connection(@connections, request)
          ensure
            @lock.unlock
          end
        end
        if connection
          f = connection.send_message(request, timeout)
          f = f.fallback do |error|
            if error.is_a?(Io::ConnectionClosedError)
              @logger.warn('Request failed because the connection closed, retrying') if @logger
              send_request(request)
            else
              raise error
            end
          end
          f.on_failure do |error|
            @logger.warn('Request failed: %s' % error.message) if @logger
          end
          f
        else
          @logger.warn('Could not send request: not connected') if @logger
          Future.failed(Io::ConnectionError.new('Not connected'))
        end
      rescue => e
        Future.failed(e)
      end

      protected

      # Override this method to send a request when a connection has been
      # established, but before the future returned by {#start} resolves.
      #
      # It's important that if you need to send a special message to initialize
      # a connection that you send it to the right connection. To do this pass
      # the connection as second argument to {#send_request}, see the example
      # below.
      #
      # @example Sending a startup request
      #   def initialize_connection(connection)
      #     send_request(MyStartupRequest.new, connection)
      #   end
      #
      # @return [Ione::Future] a future that resolves when the initialization
      #   is complete. If this future fails the connection fails.
      def initialize_connection(connection)
        Future.resolved
      end

      # Override this method to implement custom request routing strategies.
      # Before a request is encoded and sent over a connection this method will
      # be called with all available connections and the request object (i.e.
      # the object passed to {#send_request}).
      #
      # The default implementation picks a random connection.
      #
      # The connection objects have a `#host` property that use if you want to
      # do routing based on host.
      #
      # @example Routing messages consistently based on a property of the request
      #   def choose_connection(connections, request)
      #     connections[request.some_property.hash % connections.size]
      #   end
      #
      # @param [Array<Object>] connections all the open connections.
      # @param [Object] request the request to be sent.
      # @return [Object] the connection that should receive the request.
      def choose_connection(connections, request)
        connections.sample
      end

      def reconnect?(host, port, attempts)
        true
      end

      private

      def connect_all
        hosts = @lock.synchronize { @hosts.dup }
        futures = hosts.map do |host, port, promise|
          f = connect(host, port)
          promise.observe(f)
          f
        end
        Future.all(*futures)
      end

      def connect(host, port, next_timeout=nil, attempts=1)
        if @io_reactor.running?
          @logger.debug('Connecting to %s:%d' % [host, port]) if @logger
          f = @io_reactor.connect(host, port, @connection_timeout) do |connection|
            create_connection(connection)
          end
          f.on_value(&method(:handle_connected))
          f = f.fallback do |e|
            if connect?(host, port) && reconnect?(host, port, attempts)
              timeout = next_timeout || @connection_timeout
              max_timeout = @connection_timeout * 10
              next_timeout = [timeout * 2, max_timeout].min
              @logger.warn('Failed connecting to %s:%d, will try again in %ds' % [host, port, timeout]) if @logger
              ff = @io_reactor.schedule_timer(timeout)
              ff.flat_map do
                connect(host, port, next_timeout, attempts + 1)
              end
            else
              @logger.info('Not reconnecting to %s:%d' % [host, port]) if @logger
              remove_host(host, port)
              raise e
            end
          end
          f.flat_map do |connection|
            initialize_connection(connection).map(connection)
          end
        else
          Future.failed(Io::ConnectionError.new('IO reactor stopped while connecting to %s:%d' % [host, port]))
        end
      end

      def create_connection(raw_connection)
        Ione::Rpc::ClientPeer.new(raw_connection, @codec, @io_reactor, @max_channels)
      end

      def handle_connected(connection)
        @logger.info('Connected to %s:%d' % [connection.host, connection.port]) if @logger
        connection.on_closed { |error| handle_disconnected(connection, error) }
        if connect?(connection.host, connection.port)
          @lock.synchronize { @connections << connection }
        else
          connection.close
        end
      end

      def connect?(host, port)
        hosts = @lock.synchronize { @hosts.dup }
        hosts.any? { |h, p, _| h == host && p == port }
      end

      def handle_disconnected(connection, error=nil)
        message = 'Connection to %s:%d closed' % [connection.host, connection.port]
        if error
          @logger.warn(message << ' unexpectedly: ' << error.message) if @logger
        else
          @logger.info(message) if @logger
        end
        @lock.synchronize { @connections.delete(connection) }
        connect(connection.host, connection.port) if error
      end

      def normalize_address(host, port)
        if port.nil?
          host, port = host.split(':')
        end
        port = port.to_i
        return host, port
      end
    end
  end
end
