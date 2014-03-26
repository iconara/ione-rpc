# encoding: utf-8

module Ione
  module Rpc
    class Client
      def initialize(hosts, options={})
        @hosts = hosts
        @lock = Mutex.new
        @connection_timeout = options[:connection_timeout] || 5
        @io_reactor = options[:io_reactor] || Io::IoReactor.new
        @connection_initializer = options[:connection_initializer]
        @logger = options[:logger]
        @connections = []
      end

      def connected?
        @lock.synchronize { @connections.any? }
      end

      def start
        @io_reactor.start.flat_map { connect_all }.map(self)
      end

      def stop
        @lock.synchronize { @connections = [] }
        @io_reactor.stop.map(self)
      end

      def send_request(request, connection=nil)
        connection = connection || @lock.synchronize { choose_connection(@connections, request) }
        if connection
          f = connection.send_message(request)
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
      end

      protected

      def create_connection(connection)
        raise NotImplementedError, %(Client#create_connection not implemented)
      end

      def choose_connection(connections, request)
        connections.sample
      end

      private

      def connect_all
        futures = @hosts.map do |host|
          host, port = host.split(':')
          port = port.to_i
          connect(host, port)
        end
        Future.all(*futures)
      end

      def connect(host, port, next_timeout=nil)
        if @io_reactor.running?
          @logger.debug('Connecting to %s:%d' % [host, port]) if @logger
          f = @io_reactor.connect(host, port, @connection_timeout) do |connection|
            create_connection(connection)
          end
          f.on_value(&method(:handle_connected))
          f = f.fallback do |e|
            timeout = next_timeout || @connection_timeout
            max_timeout = @connection_timeout * 10
            next_timeout = [timeout * 2, max_timeout].min
            @logger.warn('Failed connecting to %s:%d, will try again in %ds' % [host, port, timeout]) if @logger
            ff = @io_reactor.schedule_timer(timeout)
            ff.flat_map { connect(host, port, next_timeout) }
          end
          f.flat_map do |connection|
            connection.send_startup_message.map(connection)
          end
        else
          Future.failed(Io::ConnectionError.new('IO reactor stopped while connecting to %s:%d' % [host, port]))
        end
      end

      def handle_connected(connection)
        @logger.info('Connected to %s:%d' % [connection.host, connection.port]) if @logger
        connection.on_closed { |error| handle_disconnected(connection, error) }
        @lock.synchronize { @connections << connection }
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
    end
  end
end
