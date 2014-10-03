# Ione RPC framework

[![Build Status](https://travis-ci.org/iconara/ione-rpc.png?branch=master)](https://travis-ci.org/iconara/ione-rpc)
[![Coverage Status](https://coveralls.io/repos/iconara/ione-rpc/badge.png)](https://coveralls.io/r/iconara/ione-rpc)
[![Blog](http://b.repl.ca/v1/blog-ione-ff69b4.png)](http://architecturalatrocities.com/tagged/ione)

_If you're reading this on GitHub, please note that this is the readme for the development version and that some features described here might not yet have been released. You can find the readme for a specific version either through [rubydoc.info](http://rubydoc.info/find/gems?q=ione-rpc) or via the release tags ([here is an example](https://github.com/iconara/ione-rpc/tree/v1.0.0))._

Ione RPC is a framework for writing server and client components for your Ruby applications. You need to write the request handling logic, but the framework handles most of the hard things for you – including automatic reconnections, load balancing, framing and request multiplexing.

# Installing

Ione RPC is available from [Rubygems][https://rubygems.org] and can be installed with the `gem` command:

```
$ gem install ione-rpc
```

but more commonly you will add it to your `Gemfile`:

```ruby
gem 'ione-rpc'
```

# Example

To communicate the client and the server need to agree on how messages should be encoded. In Ione RPC the client and server need a _codec_ which they will use to encode and decode messages. The easiest way to create a codec is to use `Ione::Rpc::StandardCodec` which takes an object that conforms to the (more or less) standard Ruby encoder protocol that libraries like JSON, YAML, MessagePack and others implement: `#dump` for encoding, `#load` for decoding (technically it's `.dump` and `.load`, but it depends on the perspective).

`StandardCodec` is stateless, so you can assign your codec to a constant:

```ruby
CODEC = Ione::Rpc::StandardCodec(JSON)
```

Using JSON for encoding isn't the most efficient, but you can easily change to MessagePack when needed, or write a little bit more code and use something like [Protocol Buffers](https://code.google.com/p/protobuf/).

### A server

When we have a codec the next step is to create the server component. Servers need to implement the `#handle_request` method, and return a future with the response.

```ruby
class TranslateServer < Ione::Rpc::Server
  def initialize(port)
    super(port, MY_CODEC)
  end

  def handle_request(request, _)
    case request['message']
    when 'Hello world'
      Ione::Future.resolved('translation' => 'Hallo welt')
    else
      Ione::Future.resolved('error' => 'Entschuldigung, ich verstehe nich')
    end
  end
end
```

It might seem like unnecessary overhead to have to create a future when you just want to return a response – but think of the possibilities: the request handling can be completely asynchronous. Your server will most likely just transform the request into one or more requests to a database, or other network services, and if they are handled asynchronously your server will use very few resources and be able to process lots of requests.

Please note that you must absolutely not do any blocking operations in `#handle_request` as they would block the whole server.

When you have your server class you need to instantiate it and start it:

```ruby
server = TranslateServer.new(3333)
started_future = server.start
started_future.on_value do |s|
  puts "Server running on port #{s.port}"
end
```

Servers can implement a method called `#handle_connection` to get notified when a client connects – this can be used create some kind of per-connection state, for example – and there are some options that can be set to control low level network settings, but apart from that, but most of the time the code you see above is all that is required.

The server will run in a background thread. If your application is just the server you need to make sure that the main application thread doesn't exit, because that means that the process will exit and the server stops. You can call `sleep` with no argument to put the main thread to sleep forever. The application will still exit when `kill`ed, on ctrl-C, or when you call `Kernel.exit`.

### A client

The client is even simpler than the server. In its simplest form this is all you need:

```ruby
client = Ione::Rpc::Client.new(CODEC, hosts: %w[node1.example.com:3333 node2.example.com:3333])
```

You can give the client a list of a single host, or many, it will connect to them all and randomize which one to talk to for each request. When a connection is lost the client will automatically try to reconnect, but use the other connections for requests in the meantime.

You can add more hosts with `#add_host` and you can tell the client to disconnect from a host (or stop trying to reconnect) with `#remove_host`.

To send requests you need to start your client, and then use `#send_request`:

```ruby
started_future = client.start
started_future.on_value do
  response_future = client.send_request('message' => 'Hello world')
  response_future.on_value do |response|
    puts response['translation']
  end
end
```

The client takes care of encoding your request into bytes and send them over the network to the server, wait for the response, decode the response and deliver it back to your code.

Maybe you got a bit of a yucky feeling when you read the code above? Did it remind you of the callback hell from Node.js? Everything in Ione RPC that is not instantaneous returns a future. Futures are more pleasant to work with than callbacks, because they compose, so let's rewrite it to take advantage of the combinatorial powers of futures:

```ruby
response_future = client.start.flat_map do |client|
  client.send_request('message' => 'Hello world')
end
translation_future = response_future.map do |response|
  response['translation']
end
translation_future.on_value do |translation|
  puts translation
end
```

That's better. It's still callbacks, of sorts, but these compose. `Ione::Future#flat_map` lets you chain asynchronous operations together and get a future that is the result of the last operation. `Ione::Future#map` is the non-asynchronous version that just transforms the result of a future to something else, just like `Array#map`.

If any of the operations in the chain fail the returned future fails and the operations after the failing one are never performed. There's a more complex example of working with futures further down.

If you don't care about being asynchronous you can use `Ione::Future#value` to wait for the result of a future to be available:

```ruby
client.start.value
response = client.send_request('message' => 'Hello world').value
puts response['translation']
```

If you choose to do it the asynchronous way just remember to not do any blocking operations (like calling `#value` on a future) in methods like `#flat_map`, `#map` or `#on_value`. Doing that will block the whole IO system and can lead to very strange bugs.

# A more advanced client

As you saw above you don't need to create a client class, but if you do there's some more features you can use.

First of all creating a client class means that you can hide the shape of the messages and present a higher level interface:

```ruby
class TranslationClient < Ione::Rpc::Client
  def initialize(hosts)
    super(CODEC, hosts: hosts)
  end

  def translate(message)
    send_request('message' => message)
  end
end
```

If you read the part above about how the client randomly selected which server to talk to and though that that wasn't very useful, there's a way to override that, just implement `#choose_connection`:

```ruby
class TranslationClient < Ione::Rpc::Client
  def initialize(hosts)
    super(CODEC, hosts: hosts)
  end

  def translate(message)
    send_request('message' => message, 'routing_key' => message.hash)
  end

  def choose_connection(connections, request)
    connections[request['routing_key'] % connections.size]
  end
end
```

The `#choose_connection` method lets you decide which connection to use for each request. In this example the connection is selected based on the hash of the message, which means that every time the message "Hello world" is sent it will be sent to the same server, but other messages will be sent to others. It doesn't say _which_ server to choose, just that it should always be the same. The connection objects implement `#host` and `#port` so if you want to do routing that picks a specific server that's possible too.

As mentioned above, when a server goes down the client will try to reconnect to it. By default it will try to reconnect forever, at decreasing intervals (up to a max which by default is around a minute), or until you call `#remove_host`. You can control how many times the client will try to reconnect by implementing `#reconnect?`:

```ruby
class TranslationClient < Ione::Rpc::Client
  # ...

  def reconnect?(host, port, attempts)
    attempts < 5
  end
```

The method gets the host and port and the number of attempts, and if you return false the reconnection attempts will stop and the host/port combination will be removed, just as if you called `#remove_host`.

Sometimes you implement a protocol that requires the client to send a "startup" message, something that initializes the connections, a hello from the client if you will. You can do this manually, but there's also a special hook for that:

```ruby
class TranslationClient < Ione::Rpc::Client
  # ...

  def initialize_connection(connection)
    send_request({'hello' => {'from' => 'me'}}, connection)
  end
end
```

`#initialize_connection` gets the newly established connection as argument and must return a future that resolves when the connection has been properly initialized. You can use the special form of `#send_request` that takes a second argument to send a requets on a specific connection – this is very important, otherwise your initialization message could be sent over another connection, which wouldn't be very useful.

# Working with futures

```ruby
all_done_future = update_user_awesomeness('sue@example.com', 8)
all_done_future.on_value do
  puts 'All done'
end

# ...

def update_user_awesomeness(email, new_awesomeness_level)
  posts_future = @db.execute('SELECT id FROM posts WHERE author = ?', email)
  # #flat_map composes two asynchronous operations, it returns immediately with a new
  # future that resolves only when the whole chain of operations is complete.
  # In other words: the block below will not run now, but when there is a result
  # from the database query. The future that is returned *represents* the result
  # of the chain of operations performed on the initial result from the database.
  posts_future.flat_map do |result|
    # Don't confuse the #map below with Future#map, this is just a regular
    # Array#map, transforming each row from the database query into something new.
    update_futures = result.map do |row|
      # Each row is used to send another database query, which returns another
      # future, so the result of this #map block will be an array of futures.
      update_post_awesomeness(row['id'], new_awesomeness_level)
    end
    # The database queries launched in the #map block will all execute in parallel
    # but we want to know when all of them are done. For this we can use Future.all,
    # which (surprise!) returns a new future, but one that resolves when *all* of the
    # source futures resolve – it lets you converge after launching multiple parallel
    # operations. Future.all transforms a list of futures of values to a future of a
    # list of values, or in pseudo types: List[Future[V]] -> Future[List[V]].
    Ione::Futures.all(*update_futures)
  end
  # We end up here almost immediately since the #flat_map doesn't run its block,
  # until it has to. What we return is the return value from the #flat_map call, which is a
  # future that will eventually resolve when all of the parallel operations we
  # launched are done
end

def update_post_awesomeness(id, new_awesomeness_level, retry_attempts=3)
  f = @db.execute('UPDATE posts SET awesomeness = ? WHERE id = ?', new_awesomeness_level, row['id'
  # To handle failure we'll use the complement to #flat_map, which is #fallback. When a
  # future fails, any chained operations will never happen, but sometimes you want to
  # try again, or do some other operation when an error occurs. For this you can use
  # #fallback to transform the failed operation into a successful one.
  f = f.fallback do |error|
    # Instead of the result of the parent future we get the error, and we can decide
    # what to do based on whether or not it is fatal or not.
    if error.is_a?(TryAgainError) && retry_attempts > 0
      # In this case we want to try again, so we call the method recursively
      # and decrement the number of remaning retries. This will make sure
      # that we don't try forever, it's usually a bad idea to never give up.
      update_post_awesomeness(id, new_awesomeness_level, retry_attempts - 1)
    else
      # If you can't recover from the error you can just raise it again and it will be
      # as if you didn't do anything.
      raise error
    end
  end
  f
end
```

Please refer to [the `Ione::Future` documentation](http://rubydoc.info/gems/ione/frames) for the full story on futures. Coincidentally the code above is more or less how [cql-rb](https://github.com/iconara/cql-rb), the Cassandra driver where Ione came from, works internally (everything but the `TryAgainError`).

# How to contribute

[See CONTRIBUTING.md](CONTRIBUTING.md)

# Copyright

Copyright 2014 Theo Hultberg/Iconara and contributors.

_Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License You may obtain a copy of the License at_

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

_Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License._
