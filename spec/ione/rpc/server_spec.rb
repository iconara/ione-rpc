# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Server do
      let :server do
        described_class.new(server_handler_factory, 4321, io_reactor: io_reactor)
      end

      let :server_handler_factory do
        double(:server_handler_factory)
      end

      let :io_reactor do
        r = double(:io_reactor)
        r.stub(:start).and_return(Ione::Future.resolved(r))
        r.stub(:stop).and_return(Ione::Future.resolved(r))
        r.stub(:bind).and_return(Ione::Future.resolved)
        r
      end

      before do
        server_handler_factory.stub(:call)
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
          server = described_class.new(server_handler_factory, 4321, io_reactor: io_reactor, bind_address: '1.1.1.1')
          server.start.value
          io_reactor.should have_received(:bind).with('1.1.1.1', 4321, anything)
        end

        it 'uses the specified queue size' do
          server = described_class.new(server_handler_factory, 4321, io_reactor: io_reactor, queue_size: 11)
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

      context 'when a client connects' do
        let :accept_listeners do
          []
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

        it 'creates a protocol handler for the new connection' do
          connection = double(:connection).as_null_object
          server.start.value
          handler = accept_listeners.first.call(connection)
          server_handler_factory.should have_received(:call).with(connection)
        end
      end
    end
  end
end
