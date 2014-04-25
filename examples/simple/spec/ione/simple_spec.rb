# encoding: utf-8

require 'spec_helper'
require 'ione/simple'


describe 'A simple client/server protocol setup' do
  let :io_reactor do
    Ione::Io::IoReactor.new
  end

  let :codec do
    Ione::JsonCodec.new
  end

  let :server_base_port do
    2**15 + rand(2**15)
  end

  let :servers do
    Array.new(3) do |i|
      Ione::SimpleServer.new(server_base_port + i, io_reactor: io_reactor)
    end
  end

  let :clients do
    hosts = servers.map { |s| "localhost:#{s.port}" }
    Array.new(5) do
      Ione::SimpleClient.new(io_reactor: io_reactor, hosts: hosts)
    end
  end

  before do
    Ione::Future.all(*servers.map(&:start)).value
    Ione::Future.all(*clients.map(&:start)).value
  end

  it 'sends requests and receives messages' do
    futures = clients.map do |client|
      client.send_request('foo' => 'bar')
    end
    responses = Ione::Future.all(*futures).value
    responses.should == Array.new(clients.size) { {'hello' => 'world'} }
  end
end
