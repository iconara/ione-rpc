# encoding: utf-8

require 'ione'


module Ione
  module Rpc
    class ClientPeer < Peer
      def initialize(connection, protocol, max_channels)
        super(connection, protocol)
        @lock = Mutex.new
        @channels = [nil] * max_channels
        @queue = []
      end

      def send_message(request)
        promise = Ione::Promise.new
        channel = @lock.synchronize do
          take_channel(promise)
        end
        if channel
          write_message(request, channel)
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
        if promise
          promise.fulfill(response)
        end
        flush_queue
      end

      def flush_queue
        @lock.synchronize do
          count = 0
          max = @queue.size
          while count < max
            request, promise = @queue[count]
            if (channel = take_channel(promise))
              write_message(request, channel)
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
        super
      end
    end
  end
end
