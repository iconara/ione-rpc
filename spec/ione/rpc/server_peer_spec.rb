# encoding: utf-8

require 'spec_helper'
require 'ione/rpc/peer_common'


module Ione
  module Rpc
    describe ServerPeer do
      let! :peer do
        RpcSpec::TestServerPeer.new(connection, protocol)
      end

      include_examples 'peers'
    end
  end
end

module RpcSpec
  class TestServerPeer < Ione::Rpc::ServerPeer
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
