# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Server do
      let :server do
        ServerSpec::TestServer.new(4321, codec, io_reactor: io_reactor)
      end

      let :codec do
        double(:codec)
      end

      let :io_reactor do
        r = double(:io_reactor)
        r.stub(:start).and_return(Ione::Future.resolved(r))
        r.stub(:stop).and_return(Ione::Future.resolved(r))
        r.stub(:bind).and_return(Ione::Future.resolved)
        r
      end

      before do
        codec.stub(:encode) { |msg, _| msg }
      end

      describe '#port' do
        it 'returns the port the server is listening on' do
          server.port.should == 4321
        end
      end

      describe '#start' do
        it 'starts the reactor' do
          server.start.value
          io_reactor.should have_received(:start)
        end

        it 'starts a server on the specified port' do
          server.start.value
          io_reactor.should have_received(:bind).with('0.0.0.0', 4321, 5)
        end

        it 'starts a server that binds to the specified address' do
          server = described_class.new(4321, codec, io_reactor: io_reactor, bind_address: '1.1.1.1')
          server.start.value
          io_reactor.should have_received(:bind).with('1.1.1.1', 4321, anything)
        end

        it 'uses the specified queue size' do
          server = described_class.new(4321, codec, io_reactor: io_reactor, queue_size: 11)
          server.start.value
          io_reactor.should have_received(:bind).with(anything, anything, 11)
        end

        it 'returns a future that resolves to the server' do
          server.start.value.should equal(server)
        end
      end

      describe '#stop' do
        it 'stops the reactor' do
          server.stop.value
          io_reactor.should have_received(:stop)
        end

        it 'returns a future that resolves to the server' do
          server.stop.value.should equal(server)
        end
      end

      shared_context 'client_connections' do
        let :accept_listeners do
          []
        end

        let :raw_connection do
          double(:connection)
        end

        before do
          raw_connection.stub(:on_data)
          raw_connection.stub(:on_closed)
          raw_connection.stub(:host).and_return('client.example.com')
          raw_connection.stub(:port).and_return(34534)
          raw_connection.stub(:write)
        end

        before do
          acceptor = double(:acceptor)
          acceptor.stub(:on_accept) do |&listener|
            accept_listeners << listener
          end
          io_reactor.stub(:bind) do |&callback|
            callback.call(acceptor)
            Ione::Future.resolved
          end
        end

        before do
          server.start.value
        end
      end

      context 'when a client connects' do
        include_context 'client_connections'

        before do
          accept_listeners.first.call(raw_connection)
        end

        it 'calls #handle_connection with the client connection' do
          server.connections.should have(1).item
          server.connections.first.host.should == raw_connection.host
        end
      end

      context 'when a client sends a request' do
        include_context 'client_connections'

        before do
          accept_listeners.first.call(raw_connection)
        end

        it 'calls #handle_request with the request' do
          server.connections.first.handle_message('FOOBAZ', 42)
          server.received_messages.first.should == ['FOOBAZ', server.connections.first]
        end

        it 'responds to the same peer and channel when the future returned by #handle_request is resolved' do
          promise = Promise.new
          server.override_handle_request { promise.future }
          peer = server.connections.first
          peer.stub(:write_message)
          peer.handle_message('FOOBAZ', 42)
          peer.should_not have_received(:write_message)
          promise.fulfill('BAZFOO')
          peer.should have_received(:write_message).with('BAZFOO', 42)
        end

        it 'uses the codec to encode the response' do
          codec.stub(:encode).with('BAZFOO', 42).and_return('42BAZFOO')
          server.override_handle_request { Future.resolved('BAZFOO') }
          peer = server.connections.first
          peer.handle_message('FOOBAZ', 42)
          raw_connection.should have_received(:write).with('42BAZFOO')
        end

        it 'handles that the server fails to process the request'
      end
    end
  end
end

module ServerSpec
  class TestServer < Ione::Rpc::Server
    attr_reader :connections, :received_messages

    def initialize(*)
      super
      @connections = []
      @received_messages = []
    end

    def handle_connection(peer)
      @connections << peer
    end

    def override_handle_request(&handler)
      @request_handler = handler
    end

    def handle_request(request, peer)
      @received_messages << [request, peer]
      if @request_handler
        @request_handler.call(request, peer)
      else
        super
      end
    end
  end
end
