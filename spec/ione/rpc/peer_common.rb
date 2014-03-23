# encoding: utf-8

require 'spec_helper'


shared_examples 'peers' do
  let :connection do
    RpcSpec::FakeConnection.new
  end

  let :protocol do
    double(:protocol)
  end

  context 'when setting up' do
    it 'registers itself to receive notifications when there is new data' do
      connection.data_listener.should_not be_nil
    end

    it 'registers itself to receive notifications when the connection closes' do
      connection.closed_listener.should_not be_nil
    end
  end

  context 'when receiving data' do
    let :empty_frame do
      double(:empty_frame, :partial? => true)
    end

    let :partial_frame do
      double(:partial_frame, :partial? => true)
    end

    let :complete_frame do
      double(:complete_frame, :partial? => false)
    end

    before do
      channel = 9
      protocol.stub(:decode) do |buffer, previous_frame|
        if buffer.empty?
          [empty_frame, channel]
        elsif buffer.index('FAKEPARTIALFRAME') == 0
          buffer.read(16)
          [partial_frame, channel]
        elsif buffer.index('FAKEENDOFFRAME') == 0 && previous_frame == partial_frame
          buffer.read(14)
          [complete_frame, channel]
        elsif buffer.index('FOO') == 0 || buffer.index('BAR') == 0 || buffer.index('BAZ') == 0
          buffer.read(3)
          [complete_frame, channel]
        end
      end
    end

    it 'does nothing when it\'s a partial frame' do
      connection.data_listener.call('FAKEPARTIALFRAME')
    end

    it 'stiches together frames from fragments' do
      connection.data_listener.call('FAKEPARTIALFRAME')
      connection.data_listener.call('FAKEENDOFFRAME')
      connection.written_bytes.should_not be_nil
    end

    it 'delivers the decoded frames to #handle_message' do
      connection.data_listener.call('FAKEPARTIALFRAME')
      connection.data_listener.call('FAKEENDOFFRAME')
      peer.messages.should == [[complete_frame, 9]]
    end

    it 'delivers multiple frames to #handle_message' do
      connection.data_listener.call('FOOBARBAZ')
      peer.messages.should have(3).items
    end
  end

  context 'when sending data' do
    before do
      protocol.stub(:encode) do |message, channel|
        "#{message}@#{channel}"
      end
    end

    it 'writes the encoded frame to the connection' do
      peer.send_message('FUZZBAZZ', 9)
      protocol.should have_received(:encode).with('FUZZBAZZ', 9)
      connection.written_bytes.should == Ione::ByteBuffer.new('FUZZBAZZ@9')
    end
  end
end

module RpcSpec
  class FakeConnection
    attr_reader :written_bytes, :data_listener, :closed_listener, :host, :port

    def initialize
      @host = 'example.com'
      @port = 9999
      @written_bytes = ''
    end

    def write(bytes)
      @written_bytes << bytes
    end

    def on_data(&listener)
      @data_listener = listener
    end

    def on_closed(&listener)
      @closed_listener = listener
    end
  end
end
