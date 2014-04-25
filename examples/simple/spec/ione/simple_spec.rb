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
    responses.map(&:body).should == Array.new(clients.size) { {'hello' => 'world'} }
  end
end

describe Ione::JsonCodec do
  let :codec do
    described_class.new
  end

  describe '#encode' do
    let :object do
      {'foo' => 'bar', 'baz' => 42}
    end

    let :encoded_message do
      codec.encode(object, 42)
    end

    it 'encodes the length of the frame in the first four bytes' do
      encoded_message[0, 4].unpack('N').should == [22]
    end

    it 'encodes the channel in the fifth byte' do
      encoded_message[4, 1].unpack('c').should == [42]
    end

    it 'encodes the object as JSON' do
      encoded_message[5..-1].should == '{"foo":"bar","baz":42}'
    end
  end

  describe '#decode' do
    let :object do
      {'foo' => 'bar', 'baz' => 42}
    end

    let :encoded_message do
      %(\x00\x00\x00\x16\x2a{"foo":"bar","baz":42})
    end

    it 'returns a partial message when there are less than five bytes' do
      message, _ = codec.decode(Ione::ByteBuffer.new(encoded_message[0, 4]), nil)
      message.should be_partial
    end

    it 'returns a partial message when the combined size of a previous partial message an new data is still less than the full frame size' do
      buffer = Ione::ByteBuffer.new
      buffer << encoded_message[0, 10]
      message, _ = codec.decode(buffer, nil)
      buffer << encoded_message[10, 4]
      message, _ = codec.decode(buffer, message)
      message.should be_partial
    end

    it 'returns a message and channel when it gets a full frame in one chunk' do
      message, channel = codec.decode(Ione::ByteBuffer.new(encoded_message), nil)
      message.body.should == object
      channel.should == 42
    end

    it 'returns a message and channel when it gets a full frame in chunks' do
      buffer = Ione::ByteBuffer.new
      buffer << encoded_message[0, 4]
      message, _ = codec.decode(buffer, nil)
      buffer << encoded_message[4, 10]
      message, _ = codec.decode(buffer, message)
      buffer << encoded_message[14..-1]
      message, channel = codec.decode(buffer, message)
      message.body.should == object
      channel.should == 42
    end

    it 'returns a message when it gets more bytes than needed' do
      buffer = Ione::ByteBuffer.new
      buffer << encoded_message[0, 10]
      message, _ = codec.decode(buffer, message)
      buffer << encoded_message[10..-1]
      buffer << 'fooooo'
      message, channel = codec.decode(buffer, message)
      message.body.should == object
      channel.should == 42
    end
  end
end