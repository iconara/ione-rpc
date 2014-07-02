# encoding: utf-8

require 'spec_helper'
require 'ione/rpc/peer_common'


module Ione
  module Rpc
    describe ClientPeer do
      let! :peer do
        RpcSpec::TestClientPeer.new(connection, codec, scheduler, max_channels)
      end

      let :connection do
        RpcSpec::FakeConnection.new
      end

      let :codec do
        double(:codec, recoding?: true)
      end

      let :scheduler do
        double(:scheduler)
      end

      let :max_channels do
        16
      end

      before do
        codec.stub(:decode) do |buffer, current_frame|
          message = buffer.to_s.scan(/[\w\d]+@-?\d+/).flatten.first
          if message
            payload, channel = message.split('@')
            buffer.discard(message.bytesize)
            [double(:complete, payload: payload), channel.to_i(10), true]
          else
            [double(:partial), nil, false]
          end
        end
        codec.stub(:encode) do |message, channel|
          '%s@%03d' % [message, channel]
        end
        codec.stub(:recode) do |message, channel|
          payload, _ = message.split('@')
          codec.encode(payload, channel)
        end
      end

      before do
        timer_promises = []
        scheduler.stub(:schedule_timer) do |timeout|
          timer_promises << Promise.new
          timer_promises.last.future
        end
        scheduler.stub(:timer_promises).and_return(timer_promises)
      end

      include_examples 'peers'

      context 'when the connection closes' do
        it 'fails all in-flight requests' do
          f1 = peer.send_message('hello')
          f2 = peer.send_message('world')
          connection.closed_listener.call
          expect { f1.value }.to raise_error(Io::ConnectionClosedError)
          expect { f2.value }.to raise_error(Io::ConnectionClosedError)
        end

        it 'fails queued requests' do
          fs = Array.new(max_channels + 2) { peer.send_message('foo') }
          connection.closed_listener.call
          expect { fs[0].value }.to raise_error(Io::ConnectionClosedError)
          expect { fs[max_channels].value }.to raise_error(Io::ConnectionClosedError)
        end

        it 'fails queued messages with an error that shows that the request was never sent' do
          fs = Array.new(max_channels + 2) { peer.send_message('foo') }
          connection.closed_listener.call
          expect { fs[max_channels].value }.to raise_error(Rpc::RequestNotSentError)
        end
      end

      describe '#initialize' do
        it 'raises ArgumentError when the specified max channels is more than the protocol handles' do
          expect { RpcSpec::TestClientPeer.new(connection, codec, scheduler, 2**24) }.to raise_error(ArgumentError)
        end
      end

      describe '#send_message' do
        it 'encodes and sends a request frame' do
          peer.send_message('hello')
          connection.written_bytes.should start_with('hello')
        end

        it 'uses the next available channel' do
          peer.send_message('hello')
          peer.send_message('foo')
          connection.data_listener.call('world@0')
          peer.send_message('bar')
          connection.written_bytes.should == 'hello@000foo@001bar@000'
        end

        it 'queues requests when all channels are in use' do
          (max_channels + 2).times { peer.send_message('foo') }
          connection.written_bytes.bytesize.should == max_channels * 7
        end

        it 'encodes messages when they are enqueued' do
          (max_channels + 2).times { peer.send_message('foo') }
          codec.should have_received(:encode).exactly(max_channels + 2).times
        end

        it 'sends queued requests when channels become available' do
          (max_channels + 2).times { |i| peer.send_message("foo#{i.to_s.rjust(3, '0')}") }
          length_before = connection.written_bytes.bytesize
          connection.data_listener.call('bar@003')
          connection.written_bytes[length_before, 10].should == "foo#{max_channels.to_s.rjust(3, '0')}@003"
          connection.data_listener.call('bar@003')
          connection.written_bytes[length_before + 10, 10].should == "foo#{(max_channels + 1).to_s.rjust(3, '0')}@003"
        end

        it 'returns a future that resolves to the response' do
          f = peer.send_message('foo')
          f.should_not be_resolved
          connection.data_listener.call('bar@000')
          f.value.payload.should == 'bar'
        end

        it 'fails the request when the timeout passes before the response is received' do
          f = peer.send_message('foo', 2)
          scheduler.timer_promises.first.fulfill
          expect { f.value }.to raise_error(Rpc::TimeoutError)
        end

        it 'does not fail the request when the response is received before the timeout passes' do
          f = peer.send_message('foo', 2)
          connection.data_listener.call('bar@000')
          scheduler.timer_promises.first.fulfill
          expect { f.value }.to_not raise_error
        end

        it 'fails the request when the connection is closed' do
          connection.stub(:closed?).and_return(true)
          f = peer.send_message('foo', 2)
          expect { f.value }.to raise_error(Rpc::RequestNotSentError)
        end

        context 'with a non-recoding codec' do
          let :codec do
            double(:codec, recoding?: false)
          end

          it 'encodes messages when they are dequeued' do
            (max_channels + 2).times { peer.send_message('foo') }
            codec.should have_received(:encode).exactly(max_channels).times
          end
        end
      end

      describe '#stats' do
        context 'returns a hash that' do
          it 'contains the host' do
            peer.stats.should include(host: connection.host)
          end

          it 'contains the port' do
            peer.stats.should include(port: connection.port)
          end

          it 'contains the max number of channels' do
            peer.stats.should include(max_channels: max_channels)
          end

          it 'contains the number of active channels' do
            peer.stats.should include(active_channels: 0)
            peer.send_message('hello')
            peer.stats.should include(active_channels: 1)
          end

          it 'contains the number of queued messages' do
            peer.stats.should include(queued_messages: 0)
            17.times { peer.send_message('hello') }
            peer.stats.should include(queued_messages: 1)
            connection.data_listener.call('bar@000')
            peer.stats.should include(queued_messages: 0)
          end

          it 'contains the number of sent messages' do
            peer.stats.should include(sent_messages: 0)
            17.times { peer.send_message('hello') }
            connection.data_listener.call('bar@000')
            peer.stats.should include(sent_messages: 17)
          end

          it 'contains the number of received responses' do
            peer.stats.should include(received_responses: 0)
            17.times { peer.send_message('hello') }
            connection.data_listener.call('bar@000')
            connection.data_listener.call('bar@000')
            peer.stats.should include(received_responses: 2)
          end

          it 'contains the number of timed out responses' do
            peer.stats.should include(timeouts: 0)
            peer.send_message('hello', 1)
            scheduler.timer_promises.first.fulfill
            peer.stats.should include(timeouts: 1)
          end
        end
      end
    end
  end
end

module RpcSpec
  class TestClientPeer < Ione::Rpc::ClientPeer
    attr_reader :messages

    def initialize(*)
      super
      @messages = []
    end

    def handle_message(*pair)
      @messages << pair
      super
    end

    public :send_message
  end
end
