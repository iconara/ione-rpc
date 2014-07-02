# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Client do
      let :client do
        ClientSpec::TestClient.new(codec, io_reactor: io_reactor, logger: logger, connection_timeout: 7, hosts: hosts)
      end

      let :hosts do
        %w[node0.example.com:4321 node1.example.com:5432 node2.example.com:6543]
      end

      let :io_reactor do
        running = [false]
        timer_promises = []
        r = double(:io_reactor)
        r.stub(:running?) { running[0] }
        r.stub(:schedule_timer) do |timeout|
          timer_promises << Promise.new
          timer_promises.last.future
        end
        r.stub(:timer_promises).and_return(timer_promises)
        r.stub(:start) do
          running[0] = true
          Future.resolved(r)
        end
        r.stub(:stop) do
          running[0] = false
          Future.resolved(r)
        end
        r.stub(:connect) do |host, port, _, &block|
          Future.resolved(block.call(create_raw_connection(host, port)))
        end
        r
      end

      let :codec do
        double(:codec)
      end

      let :logger do
        double(:logger, warn: nil, info: nil, debug: nil)
      end

      def create_raw_connection(host, port)
        connection = double("connection@#{host}:#{port}")
        connection.stub(:host).and_return(host)
        connection.stub(:port).and_return(port)
        connection.stub(:on_data)
        connection.stub(:on_closed)
        connection.stub(:write)
        connection.stub(:close) { connection.stub(:closed?).and_return(true) }
        connection.stub(:closed?).and_return(false)
        connection
      end

      before do
        codec.stub(:recoding?).and_return(false)
        codec.stub(:encode) { |input, channel| input }
      end

      describe '#start' do
        it 'starts the reactor' do
          client.start.value
          io_reactor.should have_received(:start)
        end

        it 'returns a future that resolves to the client' do
          client.start.value.should equal(client)
        end

        it 'connects to the specified hosts and ports using the specified connection timeout' do
          client.start.value
          io_reactor.should have_received(:connect).with('node0.example.com', 4321, 7)
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, 7)
          io_reactor.should have_received(:connect).with('node2.example.com', 6543, 7)
        end

        it 'accepts the hosts and ports as an array of pairs' do
          hosts = [['node0.example.com', 4321], ['node1.example.com', '5432']]
          client = ClientSpec::TestClient.new(codec, hosts: hosts, io_reactor: io_reactor, logger: logger, connection_timeout: 7)
          client.start.value
          io_reactor.should have_received(:connect).with('node0.example.com', 4321, 7)
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, 7)
        end

        it 'creates a protocol handler for each connection' do
          client.start.value
          client.created_connections.map(&:host).should == %w[node0.example.com node1.example.com node2.example.com]
          client.created_connections.map(&:port).should == [4321, 5432, 6543]
        end

        it 'logs when the connection succeeds' do
          client.start.value
          logger.should have_received(:info).with(/connected to node0.example\.com:4321/i)
          logger.should have_received(:info).with(/connected to node1.example\.com:5432/i)
          logger.should have_received(:info).with(/connected to node2.example\.com:6543/i)
        end

        it 'attempts to connect again when a connection fails' do
          connection_attempts = 0
          attempts_by_host = Hash.new(0)
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              Future.resolved(block.call(create_raw_connection(host, port)))
            else
              attempts_by_host[host] += 1
              if attempts_by_host[host] < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            end
          end
          client.start.value
          io_reactor.should have_received(:connect).with('node1.example.com', anything, anything).once
          attempts_by_host['node0.example.com'].should == 10
          attempts_by_host['node2.example.com'].should == 10
        end

        it 'doubles the time it waits between connection attempts up to 10x the connection timeout' do
          connection_attempts = 0
          timeouts = []
          io_reactor.stub(:schedule_timer) do |n|
            timeouts << n
            Future.resolved
          end
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          timeouts.should == [7, 14, 28, 56, 70, 70, 70, 70, 70]
        end

        it 'stops trying to reconnect when the reactor is stopped' do
          io_reactor.stub(:schedule_timer) do
            promise = Promise.new
            Thread.start do
              sleep(0.01)
              promise.fulfill
            end
            promise.future
          end
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          f = client.start
          io_reactor.stop.value
          expect { f.value }.to raise_error(Io::ConnectionError, /IO reactor stopped while connecting/i)
        end

        it 'logs each connection attempt and failure' do
          connection_attempts = 0
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts < 3
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          logger.should have_received(:debug).with(/connecting to node0\.example\.com:4321/i).once
          logger.should have_received(:debug).with(/connecting to node1\.example\.com:5432/i).exactly(3).times
          logger.should have_received(:debug).with(/connecting to node2\.example\.com:6543/i).once
          logger.should have_received(:warn).with(/failed connecting to node1\.example\.com:5432, will try again in \d+s/i).exactly(2).times
        end

        it 'sends a startup message once the connection has been established' do
          client.start.value
          client.created_connections.each { |c| c.requests.first.should == 'STARTUP' }
        end
      end

      describe '#stop' do
        it 'stops the reactor' do
          client.stop.value
          io_reactor.should have_received(:stop)
        end

        it 'returns a future that resolves to the client' do
          client.stop.value.should equal(client)
        end
      end

      describe '#send_request' do
        context 'when expecting a response' do
          before do
            client.start.value
            client.created_connections.each do |connection|
              connection.stub(:send_message).with('PING', nil).and_return(Future.resolved('PONG'))
            end
          end

          it 'returns a future that resolves to the response from the server' do
            client.send_request('PING').value.should == 'PONG'
          end

          it 'returns a failed future when called when not connected' do
            client.stop.value
            expect { client.send_request('PING').value }.to raise_error(Rpc::NoConnectionError)
          end
        end

        it 'uses the codec to encode frames' do
          client.start.value
          client.send_request('PING').value
          codec.should have_received(:encode).with('PING', anything)
        end

        it 'chooses the connection to receive the request randomly' do
          client.start.value
          1000.times { client.send_request('PING') }
          client.created_connections.each do |connection|
            connection.requests.size.should be_within(50).of(333)
          end
        end

        context 'with a timeout' do
          it 'passes the timeout to the connection' do
            client.start.value
            timeouts = []
            client.created_connections.each do |connection|
              connection.stub(:send_message) do |rq, timeout|
                timeouts << timeout
              end
            end
            client.send_request('PING', nil, 2)
            timeouts.should include(2)
          end
        end

        context 'when the client chooses the connection per request' do
          it 'asks the client to choose a connection to send the request on' do
            client.override_choose_connection do |connections, request|
              if request == 'PING'
                connections[0]
              elsif request == 'PONG'
                connections[1]
              else
                connections[2]
              end
            end
            client.start.value
            client.send_request('PING').value
            client.send_request('PING').value
            client.send_request('PONG').value
            startup_requests = 1
            client.created_connections.map { |c| c.requests.size - startup_requests }.sort.should == [0, 1, 2]
          end

          it 'fails the request when #choose_connection raises an error' do
            client.override_choose_connection do |connections, request|
              raise 'Bork'
            end
            client.start.value
            f = client.send_request('PING')
            expect { f.value }.to raise_error('Bork')
          end

          it 'fails the request when #choose_connection returns a closed connection' do
            client.override_choose_connection do |connections, request|
              c = connections.first
              c.close
              c
            end
            client.start.value
            f = client.send_request('PING')
            expect { f.value }.to raise_error(Rpc::RequestNotSentError)
          end

          it 'fails the request when #choose_connection returns nil' do
            client.override_choose_connection do |connections, request|
              nil
            end
            client.start.value
            f = client.send_request('PING')
            expect { f.value }.to raise_error(Rpc::NoConnectionError)
          end
        end
      end

      describe '#connected?' do
        it 'returns false before the client is started' do
          client.should_not be_connected
        end

        it 'returns true when the client has started' do
          client.start.value
          client.should be_connected
        end

        it 'returns false when the client has been stopped' do
          client.start.value
          client.stop.value
          client.should_not be_connected
        end

        it 'returns false when the connection has closed' do
          client.start.value
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          client.created_connections.each { |connection| connection.closed_listener.call }
          client.should_not be_connected
        end
      end

      describe '#add_host' do
        context 'when called before the client is started' do
          it 'connects to the host when the client starts' do
            client.add_host('new.example.com', 3333)
            io_reactor.should_not have_received(:connect)
            client.start.value
            io_reactor.should have_received(:connect).with('new.example.com', 3333, 7)
          end

          it 'returns a future that resolves to the client when the host has been connected to' do
            f = client.add_host('new.example.com', 3333)
            f.should_not be_resolved
            client.start.value
            f.value.should equal(client)
          end
        end

        context 'when called after the client has started' do
          it 'connects to the host immediately' do
            client.start.value
            io_reactor.should_not have_received(:connect).with('new.example.com', 3333, anything)
            client.add_host('new.example.com', 3333)
            io_reactor.should have_received(:connect).with('new.example.com', 3333, 7)
          end

          it 'returns a future that resolves to the client when the host has been connected to' do
            client.start.value
            f = client.add_host('new.example.com', 3333)
            f.value.should equal(client)
          end
        end

        it 'accepts a single host:port string' do
          client.add_host('new.example.com:3333')
          io_reactor.should_not have_received(:connect)
          client.start.value
          io_reactor.should have_received(:connect).with('new.example.com', 3333, 7)
        end

        it 'does not connect again if the host was already known' do
          client.add_host('new.example.com:3333')
          client.add_host('new.example.com:3333')
          client.start.value
          io_reactor.should have_received(:connect).with('new.example.com', 3333, 7).once
          client.add_host('new.example.com:3333')
          io_reactor.should have_received(:connect).with('new.example.com', 3333, 7).once
        end
      end

      describe '#remove_host' do
        it 'returns a future that resolves to the client future' do
          client.remove_host('new.example.com:3333').value.should equal(client)
        end

        it 'does not connect to the host when the client starts' do
          client.remove_host('node0.example.com', 4321)
          client.start.value
          io_reactor.should_not have_received(:connect).with('node0.example.com', 4321, anything)
        end

        it 'disconnects from the host when client has started' do
          client.start.value
          client.remove_host('node0.example.com', 4321)
          io_reactor.should have_received(:connect).with('node0.example.com', 4321, anything)
          connection = client.created_connections.find { |c| c.host == 'node0.example.com' }
          connection.should be_closed
        end

        context 'when the connection had already closed, but not reconnected' do
          let :timer_promise do
            Promise.new
          end

          before do
            client.start.value
            io_reactor.stub(:schedule_timer).and_return(timer_promise.future)
            io_reactor.stub(:connect).with('node0.example.com', 4321, anything).and_return(Future.failed(StandardError.new('BORK')))
            connection = client.created_connections.find { |c| c.host == 'node0.example.com' }
            connection.closed_listener.call(StandardError.new('BORK'))
            client.remove_host('node0.example.com', 4321)
            timer_promise.fulfill
          end

          it 'stops the reconnection attempts' do
            io_reactor.should have_received(:connect).with('node0.example.com', 4321, anything).exactly(3).times
          end

          it 'logs that it stopped attempting to reconnect' do
            logger.should have_received(:info).with('Not reconnecting to node0.example.com:4321')
          end
        end

        context 'when the connection is being established' do
          it 'closes the connection' do
            connection_promise = Promise.new
            connection_creation_block = nil
            io_reactor.stub(:connect).with('node0.example.com', 4321, anything) do |_, _, _, &block|
              connection_creation_block = block
              connection_promise.future
            end
            client.start
            client.remove_host('node0.example.com', 4321)
            connection = create_raw_connection('node0.example.com', 4321)
            connection_promise.fulfill(connection_creation_block.call(connection))
            connection.should have_received(:close)
          end
        end
      end

      describe '#connection_stats' do
        it 'is empty when no connections are open' do
          client.connection_stats.should be_empty
        end

        it 'returns an array of the host, port and statistics from each open connection' do
          client.start.value
          stats = client.connection_stats
          stats.should have(3).items
          stats.should include(host: 'node1.example.com', port: 5432, fake_stats: true)
        end
      end

      context 'when disconnected' do
        it 'logs that the connection closed' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call
          logger.should have_received(:info).with(/connection to node1\.example\.com:5432 closed/i)
          logger.should_not have_received(:info).with(/node0\.example\.com closed/i)
        end

        it 'logs that the connection closed unexpectedly' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          logger.should have_received(:warn).with(/connection to node1\.example\.com:5432 closed unexpectedly: BORK/i)
          logger.should_not have_received(:warn).with(/node0\.example\.com/i)
        end

        it 'logs when requests fail' do
          client.start.value
          client.created_connections.each { |connection| connection.stub(:send_message).with('PING', nil).and_return(Future.failed(StandardError.new('BORK'))) }
          client.send_request('PING')
          logger.should have_received(:warn).with(/request failed: BORK/i)
        end

        it 'attempts to reconnect' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          io_reactor.should have_received(:connect).exactly(4).times
        end

        it 'does not attempt to reconnect on a clean close' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call
          io_reactor.should have_received(:connect).exactly(3).times
        end

        it 'does not attempt to reconnect when #reconnect? returns false' do
          client.reconnect = 2
          client.start.value
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BURK'))
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, anything).exactly(3).times
        end

        it 'allows a manual reconnect after stopping automatic reconnections' do
          client.reconnect = 1
          client.start.value
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BURK'))
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, anything).exactly(2).times
          io_reactor.stub(:connect) { |h, p, _, &block| Future.resolved(block.call(create_raw_connection(h, p))) }
          client.add_host('node1.example.com', 5432).value
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, anything).exactly(3).times
        end

        it 'runs the same connection logic as #connect' do
          connection_attempts = 0
          connection_attempts_by_host = Hash.new(0)
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            connection_attempts_by_host[host] += 1
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts > 1 && connection_attempts < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          connection_attempts_by_host['node0.example.com'].should == 1
          connection_attempts_by_host['node1.example.com'].should == 10
          connection_attempts_by_host['node2.example.com'].should == 1
        end
      end

      context 'with multiple connections' do
        before do
          client.start.value
        end

        it 'sends requests over a random connection' do
          1000.times do
            client.send_request('PING')
          end
          request_fractions = client.created_connections.each_with_object({}) { |connection, acc| acc[connection.host] = connection.requests.size/1000.0 }
          request_fractions['node0.example.com'].should be_within(0.1).of(0.33)
          request_fractions['node1.example.com'].should be_within(0.1).of(0.33)
          request_fractions['node2.example.com'].should be_within(0.1).of(0.33)
        end

        it 'retries the request when it failes because a connection closed' do
          promises = [Promise.new, Promise.new]
          counter = 0
          received_requests = []
          client.created_connections.each do |connection|
            connection.stub(:send_message) do |request|
              received_requests << request
              promises[counter].future.tap { counter += 1 }
            end
          end
          client.send_request('PING')
          sleep 0.01 until counter > 0
          promises[0].fail(Io::ConnectionClosedError.new('CLOSED BORK'))
          promises[1].fulfill('PONG')
          received_requests.should have(2).items
        end

        it 'logs when a request is retried' do
          client.created_connections.each do |connection|
            connection.stub(:send_message) do
              connection.closed_listener.call
              Future.failed(Io::ConnectionClosedError.new('CLOSED BORK'))
            end
          end
          client.send_request('PING')
          logger.should have_received(:warn).with(/request failed because the connection closed, retrying/i).at_least(1).times
        end
      end
    end
  end
end

module ClientSpec
  class TestClient < Ione::Rpc::Client
    attr_reader :created_connections

    def initialize(*)
      super
      @created_connections = []
    end

    def create_connection(raw_connection)
      peer_connection = super
      @created_connections << TestConnection.new(raw_connection, peer_connection)
      @created_connections.last
    end

    def initialize_connection(connection)
      super.flat_map do
        send_request('STARTUP', connection)
      end
    end

    def override_choose_connection(&chooser)
      @connection_chooser = chooser
    end

    def choose_connection(connections, request)
      if @connection_chooser
        @connection_chooser.call(connections, request)
      else
        super
      end
    end

    def reconnect=(state)
      @reconnect = state
    end

    def reconnect?(host, port, attempts)
      if defined?(@reconnect)
        if @reconnect.is_a?(Integer)
          @reconnect > attempts
        else
          @reconnect
        end
      else
        super
      end
    end
  end

  class TestConnection
    attr_reader :closed_listener, :requests

    def initialize(raw_connection, peer_connection)
      @raw_connection = raw_connection
      @peer_connection = peer_connection
      @requests = []
    end

    def stats
      {
        :host => @peer_connection.host,
        :port => @peer_connection.port,
        :fake_stats => true,
      }
    end

    def closed?
      !!@closed
    end

    def close
      @closed = true
      @peer_connection.close
    end

    def on_closed(&listener)
      @closed_listener = listener
    end

    def host
      @raw_connection.host
    end

    def port
      @raw_connection.port
    end

    def send_message(request, timeout=nil)
      @requests << request
      @peer_connection.send_message(request, timeout)
      Ione::Future.resolved
    end
  end
end