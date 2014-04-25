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

  let :client do
    hosts = servers.map { |s| "localhost:#{s.port}" }
    Ione::SimpleClient.new(io_reactor: io_reactor, hosts: hosts)
  end

  before do
    Ione::Future.all(*servers.map(&:start), client.start).value
  end

  describe '#pi' do
    it 'returns an approximate value of π' do
      future = client.pi
      future.value.should be_within(0.000000000000001).of(Math::PI)
    end
  end

  describe '#tau' do
    it 'returns an approximate value of τ' do
      future = client.tau
      future.value.should be_within(0.000000000000001).of(Math::PI * 2)
    end
  end

  context 'when the client sends something that the server doesn\'t understand' do
    it 'responds with an error message' do
      future = client.send_request('α')
      future.value.should eql('error' => 'wat?')
    end
  end
end
