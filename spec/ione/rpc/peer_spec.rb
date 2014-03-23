# encoding: utf-8

require 'spec_helper'
require 'ione/rpc/peer_common'


module Ione
  module Rpc
    describe Peer do
      let! :peer do
        RpcSpec::TestPeer.new(connection, protocol)
      end

      include_examples 'peers'
    end
  end
end

module RpcSpec
  class TestPeer < Ione::Rpc::Peer
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
