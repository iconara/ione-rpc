# encoding: utf-8

require 'spec_helper'
require 'ione/rpc/peer_common'


module Ione
  module Rpc
    describe ClientPeer do
      let! :peer do
        RpcSpec::TestClientPeer.new(connection, protocol, 8)
      end

      include_examples 'peers'
    end
  end
end

module RpcSpec
  class TestClientPeer < Ione::Rpc::ClientPeer
    attr_reader :messages

    def initialize(*)
      super
      @messages = []
    end

    def handle_message(*pair)
      @messages << pair
    end

    public :send_message
  end
end
