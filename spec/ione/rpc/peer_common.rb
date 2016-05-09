# encoding: utf-8

require 'spec_helper'


shared_examples 'peers' do
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
      codec.stub(:recoding?).and_return(false)
      codec.stub(:decode) do |buffer, previous_frame|
        if buffer.empty?
          [empty_frame, channel, false]
        elsif buffer.index('FAKEPARTIALFRAME') == 0
          buffer.read(16)
          [partial_frame, channel, false]
        elsif buffer.index('FAKEENDOFFRAME') == 0 && previous_frame == partial_frame
          buffer.read(14)
          [complete_frame, channel, true]
        elsif buffer.index('FOO') == 0 || buffer.index('BAR') == 0 || buffer.index('BAZ') == 0
          buffer.read(3)
          [complete_frame, channel, true]
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

    it 'closes the connection when there is an error decoding a frame' do
      error = nil
      peer.on_closed { |e| error = e }
      codec.stub(:decode).with(Ione::ByteBuffer.new('FOOBARBAZ'), anything).and_raise(Ione::Rpc::CodecError.new('Bork'))
      connection.data_listener.call('FOOBARBAZ')
      error.should be_a(Ione::Rpc::CodecError)
      error.message.should == 'Bork'
    end
  end

  context 'when sending data' do
    before do
      codec.stub(:encode) do |message, channel|
        "#{message}@#{channel}"
      end
    end

    it 'writes the encoded frame to the connection' do
      peer.send_message('FUZZBAZZ')
      codec.should have_received(:encode).with('FUZZBAZZ', kind_of(Fixnum))
      connection.written_bytes.should match(/\AFUZZBAZZ@\d+\Z/)
    end
  end

  context 'when the connection closes' do
    it 'calls the closed listeners' do
      called1 = false
      called2 = false
      peer.on_closed { called1 = true }
      peer.on_closed { called2 = true }
      connection.closed_listener.call
      called1.should be_true
      called2.should be_true
    end

    it 'calls the closed listener with the close cause' do
      cause = nil
      peer.on_closed { |e| cause = e }
      connection.closed_listener.call(StandardError.new('foo'))
      cause.should == StandardError.new('foo')
    end
  end

  context 'when closed' do
    before do
      connection.stub(:close)
    end

    it 'closes the connection' do
      peer.close
      connection.should have_received(:close)
    end
  end

  describe '#closed?' do
    it 'reflects the underlying connection\'s state' do
      connection.stub(:closed?).and_return(true)
      peer.should be_closed
      connection.stub(:closed?).and_return(false)
      peer.should_not be_closed
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
      @closed = false
    end

    def closed?
      @closed
    end

    def close(cause=nil)
      @closed_listener.call(cause) if @closed_listener
      @closed = true
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
