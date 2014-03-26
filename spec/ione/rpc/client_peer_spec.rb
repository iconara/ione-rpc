# encoding: utf-8

require 'spec_helper'
require 'ione/rpc/peer_common'


module Ione
  module Rpc
    describe ClientPeer do
      let! :peer do
        RpcSpec::TestClientPeer.new(connection, protocol, max_channels)
      end

      let :connection do
        RpcSpec::FakeConnection.new
      end

      let :protocol do
        double(:protocol)
      end

      let :max_channels do
        16
      end

      before do
        protocol.stub(:decode) do |buffer, current_frame|
          message = buffer.to_s.scan(/[\w\d]+@\d+/).flatten.first
          if message
            payload, channel = message.split('@')
            buffer.discard(message.bytesize)
            [double(:partial? => false, payload: payload), channel.to_i(10)]
          else
            [double(:partial? => true), nil]
          end
        end
        protocol.stub(:encode) do |message, channel|
          '%s@%03d' % [message, channel]
        end
      end

      include_examples 'peers'

      context 'when the connection closes' do
        it 'fails all outstanding requests when closing' do
          f1 = peer.send_message('hello')
          f2 = peer.send_message('world')
          connection.closed_listener.call
          expect { f1.value }.to raise_error(Io::ConnectionClosedError)
          expect { f2.value }.to raise_error(Io::ConnectionClosedError)
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
      end

      describe '#send_startup_message' do
        it 'does nothing by default' do
          peer.send_startup_message.value
          connection.written_bytes.should be_empty
        end

        it 'uses the block given to the constructor to create a startup message' do
          peer = RpcSpec::TestClientPeer.new(connection, protocol, max_channels) { |s| "start/#{s.host}" }
          peer.send_startup_message
          connection.written_bytes.should == 'start/example.com@000'
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
