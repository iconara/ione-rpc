# encoding: utf-8

require 'ione'


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
          message, channel = @protocol.decode(@buffer, @current_message)
          break if message.partial?
          handle_message(message, channel)
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

    class ServerPeer < Peer; end

    class ClientPeer < Peer
      def initialize(connection, protocol, max_channels)
        super(connection, protocol)
        @lock = Mutex.new
        @channels = [nil] * max_channels
        @queue = []
      end

      def on_closed(&listener)
        @closed_listener = listener
      end

      def send_request(request)
        promise = Ione::Promise.new
        channel = @lock.synchronize do
          take_channel(promise)
        end
        if channel
          send_message(request, channel)
        else
          @lock.synchronize do
            @queue << [request, promise]
          end
        end
        promise.future
      end

      private

      def handle_message(response, channel)
        promise = @lock.synchronize do
          promise = @channels[channel]
          @channels[channel] = nil
          promise
        end
        promise.fulfill(response)
        flush_queue
      end

      def flush_queue
        @lock.synchronize do
          count = 0
          max = @queue.size
          while count < max
            request, promise = @queue[count]
            if (channel = take_channel(promise))
              send_message(request, channel)
              count += 1
            else
              break
            end
          end
          @queue = @queue.drop(count)
        end
      end

      def take_channel(promise)
        if (channel = @channels.index(nil))
          @channels[channel] = promise
          channel
        end
      end

      def handle_closed(cause=nil)
        error = Io::ConnectionClosedError.new('Connection closed')
        promises_to_fail = @lock.synchronize { @channels.reject(&:nil?) }
        promises_to_fail.each { |p| p.fail(error) }
        @closed_listener.call(cause) if @closed_listener
      end
    end
  end
end
