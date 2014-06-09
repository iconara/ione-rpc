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
          encoded_message[0, 1].unpack('c').should == [2]
        end

        it 'encodes the channel in the third and fourth byte' do
          encoded_message[2, 2].unpack('n').should == [42]
        end

        it 'encodes the length of the frame in the following four bytes' do
          encoded_message[4, 4].unpack('N').should == [22]
        end

        it 'encodes the object as JSON' do
          encoded_message[8..-1].should == '{"foo":"bar","baz":42}'
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

      context 'when decoding and encoding' do
        let :message do
          {'foo' => 'bar', 'baz' => 42}
        end

        let :channel do
          42
        end

        let :v1_frame do
          %(\x01\x2a\x00\x00\x00\x16{"foo":"bar","baz":42})
        end

        let :v2_frame do
          %(\x02\x00\x00\x2a\x00\x00\x00\x16{"foo":"bar","baz":42})
        end

        context 'with a v1 frame' do
          it 'decodes a frame' do
            msg, ch, _ = codec.decode(Ione::ByteBuffer.new(v1_frame), nil)
            msg.should == message
          end
        end

        context 'with a v2 frame' do
          it 'decoding a encoded frame returns the original message' do
            frm = codec.encode(message, channel)
            msg, ch, _ = codec.decode(Ione::ByteBuffer.new(frm), nil)
            msg.should == message
            ch.should == channel
          end

          it 'encoding a message gives the original frame' do
            msg, ch, _ = codec.decode(Ione::ByteBuffer.new(v2_frame), nil)
            frm = codec.encode(msg, ch)
            frm.should == v2_frame
          end
        end
      end
    end

    describe StandardCodec do
      let :codec do
        described_class.new(JSON)
      end

      describe '#encode' do
        it 'calls #dump on the delegate' do
          codec.encode({'foo' => 'bar'}, 0)[8..-1].should == '{"foo":"bar"}'
        end
      end

      describe '#decode' do
        it 'calls #load on the delegate' do
          buffer = Ione::ByteBuffer.new(%(\x02\x00\x00\x00\x00\x00\x00\x0d{"foo":"bar"}))
          message, _, _ = codec.decode(buffer, nil)
          message.should eql('foo' => 'bar')
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
