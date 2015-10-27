# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Server do
      let :server do
        ServerSpec::TestServer.new(4321, codec, io_reactor: io_reactor, logger: logger)
      end

      let :codec do
        double(:codec)
      end

      let :logger do
        double(:logger, debug: nil, info: nil, warn: nil, error: nil)
      end

      let :acceptor do
        double(:acceptor)
      end

      let :io_reactor do
        double(:io_reactor)
      end

      before do
        io_reactor.stub(:start).and_return(Ione::Future.resolved(io_reactor))
        io_reactor.stub(:stop).and_return(Ione::Future.resolved(io_reactor))
        io_reactor.stub(:bind) do |*args, &callback|
          callback.call(acceptor)
          Ione::Future.resolved
        end
      end

      before do
        acceptor.stub(:on_accept)
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

        it 'logs the address and port when listening for connections' do
          server.start.value
          logger.should have_received(:info).with('Server listening for connections on 0.0.0.0:4321')
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
          raw_connection.stub(:on_closed) { |&listener| raw_connection.stub(:closed_listener).and_return(listener) }
          raw_connection.stub(:host).and_return('client.example.com')
          raw_connection.stub(:port).and_return(34534)
          raw_connection.stub(:write)
        end

        before do
          acceptor.stub(:on_accept) do |&listener|
            accept_listeners << listener
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

        it 'logs that a client connected' do
          logger.should have_received(:info).with('Connection from client.example.com:34534 accepted')
        end

        it 'logs when the client is disconnected' do
          raw_connection.closed_listener.call
          logger.should have_received(:info).with('Connection from client.example.com:34534 closed')
        end

        it 'logs when the client is disconnected unexpectedly' do
          raw_connection.closed_listener.call(IOError.new('Boork'))
          logger.should have_received(:warn).with('Connection from client.example.com:34534 closed unexpectedly: Boork (IOError)')
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
          sent_pair = nil
          codec.stub(:encode) do |response, channel|
            sent_pair = [response, channel]
            response
          end
          promise = Promise.new
          server.override_handle_request { promise.future }
          peer = server.connections.first
          peer.handle_message('FOOBAZ', 42)
          sent_pair.should be_nil
          promise.fulfill('BAZFOO')
          sent_pair.should == ['BAZFOO', 42]
        end

        it 'uses the codec to encode the response' do
          codec.stub(:encode).with('BAZFOO', 42).and_return('42BAZFOO')
          server.override_handle_request { Future.resolved('BAZFOO') }
          peer = server.connections.first
          peer.handle_message('FOOBAZ', 42)
          raw_connection.should have_received(:write).with('42BAZFOO')
        end

        context 'and there is an error' do
          before do
            codec.stub(:encode).with('BAZFOO', 42).and_return('42BAZFOO')
          end

          it 'calls #handle_error when #handle_request raises an error' do
            server.override_handle_request { raise 'Borkzor' }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            server.errors.first.message.should == 'Borkzor'
          end

          it 'calls #handle_error when #handle_request returns a failed future' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            server.errors.should == [StandardError.new('Borkzor')]
          end

          it 'calls #handle_error with the error, the request, no response, and the connection' do
            error, request, response, connection = nil, nil, nil, nil
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e, q, r, c| error = e; request = q; response = r; connection = c }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            error.should be_a(StandardError)
            error.message.should eq('Borkzor')
            request.should eq('FOOBAZ')
            response.should be_nil
            connection.should equal(peer)
          end

          it 'responds with the message returned by #handle_error' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e| Ione::Future.resolved("OH NOES: #{e.message}") }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            raw_connection.should have_received(:write).with('OH NOES: Borkzor')
          end

          it 'does not respond at all by default' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            raw_connection.should_not have_received(:write)
          end

          it 'does not respond when #handle_error raises an error' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e| raise "OH NOES: #{e.message}" }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            raw_connection.should_not have_received(:write)
          end

          it 'does not respond when #handle_error returns a failed future' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e| Ione::Future.failed(StandardError.new("OH NOES: #{e.message}")) }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            raw_connection.should_not have_received(:write)
          end

          it 'logs unhandled errors' do
            server.override_handle_request { raise StandardError, 'Borkzor' }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            logger.should have_received(:error).with(/^Unhandled error for client.example.com:34534; Borkzor \(StandardError\)/i)
            logger.should have_received(:debug).with(/\d+:in/)
          end

          it 'logs when #handle_error raises an error' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e| raise StandardError, "OH NOES: #{e.message}" }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            logger.should have_received(:error).with(/^Unhandled error for client.example.com:34534; OH NOES: Borkzor \(StandardError\)/i)
          end

          it 'logs when #handle_error returns a failed future' do
            server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
            server.override_handle_error { |e| Ione::Future.failed(StandardError.new("OH NOES: #{e.message}")) }
            peer = server.connections.first
            peer.handle_message('FOOBAZ', 42)
            logger.should have_received(:error).with(/^Unhandled error for client.example.com:34534; OH NOES: Borkzor \(StandardError\)/i)
          end

          context 'when the codec fails to encode the response' do
            it 'calls #handle_error' do
              server.override_handle_request { Ione::Future.resolved('OK') }
              codec.stub(:encode).with('OK', 42).and_raise(CodecError.new('Borkzor'))
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              server.errors.first.should be_a(CodecError)
              server.errors.first.message.should == 'Borkzor'
            end

            it 'calls #handle_error with the error, the request, the response, and the connection' do
              error, request, response, connection = nil, nil, nil, nil
              server.override_handle_request { Ione::Future.resolved('OK') }
              server.override_handle_error { |e, q, r, c| error = e; request = q; response = r; connection = c }
              codec.stub(:encode).with('OK', 42).and_raise(CodecError.new('Borkzor'))
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              error.should be_a(CodecError)
              error.message.should eq('Borkzor')
              request.should eq('FOOBAZ')
              response.should eq('OK')
              connection.should equal(peer)
            end

            it 'responds with what #handle_error responds with' do
              server.override_handle_request { Ione::Future.resolved('OK') }
              server.override_handle_error { |e| Ione::Future.resolved("ERROR: #{e.message}") }
              codec.stub(:encode).with('OK', 42).and_raise(CodecError.new('Borkzor'))
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              raw_connection.should have_received(:write).with('ERROR: Borkzor')
            end

            it 'does not respond when the codec cannot encode the response returned by #handle_error' do
              server.override_handle_request { Ione::Future.resolved('OK') }
              server.override_handle_error { |e| Ione::Future.resolved("ERROR: #{e.message}") }
              codec.stub(:encode).with('OK', 42).and_raise(CodecError.new('Borkzor'))
              codec.stub(:encode).with('ERROR: Borkzor', 42).and_raise(CodecError.new('Buzzfuzz'))
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              raw_connection.should_not have_received(:write)
              server.errors.should have(1).item
            end

            it 'logs when the codec cannot encode the response returned by #handle_error' do
              server.override_handle_request { Ione::Future.resolved('OK') }
              server.override_handle_error { |e| Ione::Future.resolved("ERROR: #{e.message}") }
              codec.stub(:encode).with('OK', 42).and_raise(CodecError.new('Borkzor'))
              codec.stub(:encode).with('ERROR: Borkzor', 42).and_raise(CodecError.new('Buzzfuzz'))
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              logger.should have_received(:error).with(/^Unhandled error for client.example.com:34534; Buzzfuzz \(Ione::Rpc::CodecError\)/i)
            end
          end

          context 'with a legacy server subclass' do
            let :server do
              ServerSpec::LegacyTestServer.new(4321, codec, io_reactor: io_reactor, logger: logger)
            end

            it 'calls #handle_error with the error, the request and the connection for legacy servers' do
              error, request, response, connection = nil, nil, nil, nil
              server.override_handle_request { Ione::Future.failed(StandardError.new('Borkzor')) }
              server.override_handle_error { |e, q, r, c| error = e; request = q; response = r; connection = c }
              peer = server.connections.first
              peer.handle_message('FOOBAZ', 42)
              error.should be_a(StandardError)
              error.message.should eq('Borkzor')
              request.should eq('FOOBAZ')
              response.should eq(:legacy)
              connection.should equal(peer)
            end
          end
        end
      end
    end
  end
end

module ServerSpec
  class TestServer < Ione::Rpc::Server
    attr_reader :connections, :received_messages, :errors

    def initialize(*)
      super
      @connections = []
      @received_messages = []
      @errors = []
    end

    def handle_connection(peer)
      @connections << peer
    end

    def override_handle_error(&handler)
      @error_handler = handler
    end

    def override_handle_request(&handler)
      @request_handler = handler
    end

    def handle_error(error, request, response, connection)
      @errors << error
      if @error_handler
        @error_handler.call(error, request, response, connection)
      else
        super
      end
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

  class LegacyTestServer < TestServer
    def handle_error(error, request, connection)
      super(error, request, :legacy, connection)
    end
  end
end
