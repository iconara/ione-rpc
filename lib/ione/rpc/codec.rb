# encoding: utf-8

module Ione
  module Rpc
    CodecError = Class.new(StandardError)

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
    # Codecs must be stateless.
    #
    # Codecs must also make sure that these (conceptual) invariants hold:
    # `decode(encode(message, channel)) == [message, channel]` and
    # `encode(decode(frame)) == frame` (the return values are not entirely
    # compatible, but the concept should be clear).
    #
    # Codecs can be configured to compress frame bodies by giving them a
    # compressor. A compressor is an object that responds to `#compress`,
    # `#decompress` and `#compress?`. The first takes a string and returns
    # a compressed string, the second does the reverse and the third is a way
    # for the compressor to advice the codec whether or not it's meaningful to
    # encode the frame at all. `#compress?` will get the same argument as
    # `#compress` and should return true or false. It could for example return
    # true when the frame size is over a threshold value.
    class Codec
      # @param [Hash] options
      # @option options [Object] :compressor a compressor to use to compress
      #   and decompress frames (see above for the required interface it needs
      #   to implement).
      def initialize(options={})
        @compressor = options[:compressor]
      end

      # Encodes a frame with a header that includes the frame size and channel,
      # and the message as body.
      #
      # Will compress the frame body and set the compression flag when the codec
      # has been configured with a compressor, and it says the frame should be
      # compressed.
      #
      # @param [Object] message the message to encode
      # @param [Integer] channel the channel to encode into the frame
      # @return [String] an encoded frame with the message and channel
      def encode(message, channel)
        data = encode_message(message)
        flags = 0
        if @compressor && @compressor.compress?(data)
          data = @compressor.compress(data)
          flags |= COMPRESSION_FLAG
        end
        [2, flags, channel, data.bytesize, data.to_s].pack(FRAME_V2_FORMAT)
      end

      # Decodes a frame, piece by piece if necessary.
      #
      # When the compression flag is set the codec uses the configured compressor
      # to decode the frame before passing the decompressed bytes to
      # {#decode_message}.
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
      # @raise [Ione::Rpc::CodecError] when a frame has the compression flag set
      #   and the codec is not configured with a compressor.
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
          body = state.read_body
          if state.compressed?
            if @compressor
              body = @compressor.decompress(body)
            else
              raise CodecError, 'Compressed frame received but no compressor available'
            end
          end
          return decode_message(body), state.channel, true
        else
          return state, nil, false
        end
      end

      # Whether or not this codec supports channel recoding, see {#recode}.
      def recoding?
        true
      end

      # Recode the channel of a frame.
      #
      # This is used primarily by the client when it needs to queue a request
      # because all channels are occupied. When the codec supports recoding the
      # client can encode the request when it is queued, instead of when it is
      # dequeued. This means that in most cases the calling thread will do the
      # encoding instead of the IO reactor thread.
      #
      # @param [String] bytes an encoded frame (the output from {#encode})
      # @param [Integer] channel the channel to encode into the frame
      # @return [String] the reencoded frame
      def recode(bytes, channel)
        bytes[2, 2] = [channel].pack(CHANNEL_FORMAT)
        bytes
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
          @compressed = n & COMPRESSION_FLAG == COMPRESSION_FLAG
          if @version == 1
            @channel = n & 0xff
          else
            @channel = @buffer.read_short
          end
          @length = @buffer.read_int
        end

        def read_body
          @buffer.read(@length)
        end

        def header_ready?
          @length.nil? && @buffer.size >= 8
        end

        def body_ready?
          @length && @buffer.size >= @length
        end

        def compressed?
          @compressed
        end
      end

      private

      FRAME_V1_FORMAT = 'ccNa*'.freeze
      FRAME_V2_FORMAT = 'ccnNa*'.freeze
      CHANNEL_FORMAT = 'n'.freeze
      COMPRESSION_FLAG = 1
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
