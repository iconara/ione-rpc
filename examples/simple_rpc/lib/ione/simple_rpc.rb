# encoding: utf-8

require 'ione/rpc'
require 'json'
require 'logger'


module Ione
  # A "standard" codec uses an object that follows the more or less standard
  # Ruby convention of using #dump and #load for encoding and decoding,
  # respectively. In this example we use JSON, but you can exchange it for
  # YAML, MessagePack, or any other encoder that uses the standard. The codec
  # is used to encode messages and for the framing, which is some extra bytes
  # prepended on the encoded message that makes it possible to know how many
  # bytes to consume when decoding, and how to route the message.
  CODEC = Ione::Rpc::StandardCodec.new(JSON)

  # This is the server component, you need to create an instance of this class
  # and call #start to run it (see bin/server for an example).
  class SimpleRpcServer < Ione::Rpc::Server
    def initialize(port, options={})
      # The server needs to know which port to listen on, and which codec to use
      # to decode requests and encode responses. The codec must be the same for
      # both the server and client (not the same instance necessarily, as it is
      # in this example).
      super(port, CODEC, options)
    end

    # This is where you need to put your request handling code. The method must
    # return a future that contains the response to send back to the client.
    # The method takes two parameters: the message and the connection it was
    # received on, but most of the time you only need the first.
    def handle_request(message, _)
      response = begin
        case message
        when 'π'
          Math::PI
        when 'τ'
          Math::PI * 2
        else
          # It's important to always have a response, so when you don't
          # understand the message, have a standardized error response
          {'error' => 'wat?'}
        end
      end
      # The message handler *must* respond with future. This might be inconvenient
      # when you're doing something simple as returning static strings, but most
      # of the time you're talking to a database or another service and then
      # being able to do that asynchronously is very useful.
      Future.resolved(response)
    end
  end

  # This is the client component, you need to create an instance of this class,
  # give it the host and port of the server(s) and call #start on it to make it
  # connect. Then you can call the #pi and #tau methods to send messages to the
  # server(s).
  class SimpleRpcClient < Ione::Rpc::Client
    def initialize(options={})
      super(CODEC, options)
    end

    # You could just create an instance of Ione::Rpc::Client and call #send_request
    # on it, but it's nice to present a higher level API to your users. The
    # server supports calculating π and τ and these methods abstracts these calls.

    def pi
      send_request('π')
    end

    def tau
      send_request('τ')
    end
  end
end
