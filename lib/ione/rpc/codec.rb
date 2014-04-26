# encoding: utf-8

module Ione
  module Rpc
    # Codecs are used to encode and decode the messages sent between the client
    # and server. Codecs must be able to decode frames in a streaming fashion,
    # i.e. frames that come in pieces.
    #
    # If you want to control how messages are framed you can implement your
    # own codec from scratch by implementing {#encode} and {#decode}, but most
    # of the time you should only need to implement {#encode_message} and
    # {#decode_message} which take care of encoding and decoding the message,
    # and leave the framing to the default implementation. If you decide to
    # implement {#encode} and {#decode} you don't need to subclass this class.
    #
    # Codecs must be stateless.
    #
    # Codecs must also make sure that these (conceptual) invariants hold:
    # `decode(encode(message, channel)) == [message, channel]` and
    # `encode(decode(frame)) == frame` (the return values are not entirely
    # compatible, but the concept should be clear).
    class Codec
      # Encodes a frame with a header that includes the frame size and channel,
      # and the message as body.
      #
      # @param [Object] message the message to encode
      # @param [Integer] channel the channel to encode into the frame
      # @return [String] an encoded frame with the message and channel
      def encode(message, channel)
        data = encode_message(message)
        [1, channel, data.bytesize, data.to_s].pack('ccNa*')
      end

      # Decodes a frame, piece by piece if necessary.
      #
      # Since the IO layer has no knowledge about the framing it can't know
      # how many bytes are needed before a frame can be fully decoded so instead
      # the codec needs to be able to process partial frames. At the same time
      # a codec can be used concurrently and must be stateless. To support partial
      # decoding a codec can return a state instead of a decoded message until
      # a complete frame can be decoded.
      #
      # The codec must return three values: the last value must be true if a
      # if a message was decoded fully, and false if not enough bytes were
      # available. When it is true the first piece is the message and the second
      # the channel. When it is false the first piece is the partial decoded
      # state (this can be any object at all) and the second is nil. The partial
      # decoded state will be passed in as the second argument on the next call.
      #
      # In other words: the first time {#decode} is called the second argument
      # will be nil, but on subsequent calls, until the third return value is
      # true, the second argument will be whatever was returned by the previous
      # call.
      #
      # The buffer might contain more bytes than needed to decode a frame, and
      # the implementation must not consume these. The implementation must
      # consume all of the bytes of the current frame, but none of the bytes of
      # the next frame.
      #
      # @param [Ione::ByteBuffer] buffer the byte buffer that contains the frame
      #   data. The byte buffer is owned by the caller and should only be read from.
      # @param [Object, nil] state the first value returned from the previous
      #   call, unless the previous call resulted in a completely decoded frame,
      #   in which case it is nil
      # @return [Array<Object, Integer, Boolean>] three values where the last is
      #   true when a frame could be completely decoded. When the last value is
      #   true the first value is the decoded message and the second the channel,
      #   but when the last value is false the first is the partial state (see
      #   the `state` parameter) and the second is nil.
      def decode(buffer, state)
        state ||= State.new(buffer)
        if state.header_ready?
          state.read_header
        end
        if state.body_ready?
          return decode_message(state.read_body), state.channel, true
        else
          return state, nil, false
        end
      end

      # @!method encode_message(message)
      #
      # Encode an object to bytes that can be sent over the network.
      #
      # @param [Object] message the object to encode
      # @return [String, Ione::ByteBuffer] an object that responds to `#to_s`
      #   and `#bytesize`, for example a `String` or a `Ione::ByteBuffer`

      # @!method decode_message(str)
      #
      # Decode a string of bytes to an object.
      #
      # @param [String] str an encoded message, the same string that was produced
      #   by {#encode_message}
      # @return [Object] the decoded message

      # @private
      class State
        attr_reader :channel

        def initialize(buffer)
          @buffer = buffer
        end

        def read_header
          n = @buffer.read_short
          @version = n >> 8
          @channel = n & 0xff
          @length = @buffer.read_int
        end

        def read_body
          @buffer.read(@length)
        end

        def header_ready?
          @length.nil? && @buffer.size >= 6
        end

        def body_ready?
          @length && @buffer.size >= @length
        end
      end
    end

    # A codec that works with encoders like JSON, MessagePack, YAML and others
    # that follow the informal Ruby standard of having a `#dump` method that
    # encodes and a `#load` method that decodes.
    #
    # @example A codec that encodes messages as JSON
    #   codec = StandardCodec.new(JSON)
    #
    # @example A codec that encodes messages as MessagePack
    #   codec = StandardCodec.new(MessagePack)
    class StandardCodec < Codec
      # @param [#load, #dump] delegate
      def initialize(delegate)
        @delegate = delegate
      end

      # Uses the delegate's `#dump` to encode the message
      def encode_message(message)
        @delegate.dump(message)
      end

      # Uses the delegate's `#load` to decode the message
      def decode_message(str)
        @delegate.load(str)
      end
    end
  end
end
