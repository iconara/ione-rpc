# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Codec do
      let :codec do
        CodecSpec::JsonCodec.new
      end

      describe '#encode' do
        let :object do
          {'foo' => 'bar', 'baz' => 42}
        end

        let :encoded_message do
          codec.encode(object, 42)
        end

        it 'encodes the version in the first byte' do
          encoded_message[0, 1].unpack('c').should == [1]
        end

        it 'encodes the channel in the second byte' do
          encoded_message[1, 1].unpack('c').should == [42]
        end

        it 'encodes the length of the frame in the following four bytes' do
          encoded_message[2, 4].unpack('N').should == [22]
        end

        it 'encodes the object as JSON' do
          encoded_message[6..-1].should == '{"foo":"bar","baz":42}'
        end
      end

      describe '#decode' do
        let :object do
          {'foo' => 'bar', 'baz' => 42}
        end

        let :encoded_message do
          %(\x01\x2a\x00\x00\x00\x16{"foo":"bar","baz":42})
        end

        it 'returns a partial message when there are less than five bytes' do
          _, _, complete = codec.decode(Ione::ByteBuffer.new(encoded_message[0, 4]), nil)
          complete.should be_false
        end

        it 'returns a partial message when the combined size of a previous partial message an new data is still less than the full frame size' do
          buffer = Ione::ByteBuffer.new
          buffer << encoded_message[0, 10]
          message, _, _ = codec.decode(buffer, nil)
          buffer << encoded_message[10, 4]
          _, _, complete = codec.decode(buffer, message)
          complete.should be_false
        end

        it 'returns a message and channel when it gets a full frame in one chunk' do
          message, channel, complete = codec.decode(Ione::ByteBuffer.new(encoded_message), nil)
          complete.should be_true
          message.should == object
          channel.should == 42
        end

        it 'returns a message and channel when it gets a full frame in chunks' do
          buffer = Ione::ByteBuffer.new
          buffer << encoded_message[0, 4]
          message, _, _ = codec.decode(buffer, nil)
          buffer << encoded_message[4, 10]
          message, _, _ = codec.decode(buffer, message)
          buffer << encoded_message[14..-1]
          message, channel, _ = codec.decode(buffer, message)
          message.should == object
          channel.should == 42
        end

        it 'returns a message when it gets more bytes than needed' do
          buffer = Ione::ByteBuffer.new
          buffer << encoded_message[0, 10]
          message, _ = codec.decode(buffer, message)
          buffer << encoded_message[10..-1]
          buffer << 'fooooo'
          message, channel = codec.decode(buffer, message)
          message.should == object
          channel.should == 42
        end
      end
    end
  end
end

module CodecSpec
  class JsonCodec < Ione::Rpc::Codec
    def encode_message(message)
      JSON.dump(message)
    end

    def decode_message(str)
      JSON.load(str)
    end
  end
end
