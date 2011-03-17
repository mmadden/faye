module Faye
  class Server
    
    include Logging
    include Extensible
    
    def initialize(options = {})
      @options     = options
      @connections = {}
      @engine      = Faye::Engine.get(options)
      
      @engine.add_subscriber(:message, method(:on_message))
      @engine.add_subscriber(:disconnect, method(:on_disconnect))
    end
    
  private
    
    def on_message(client_id, message)
      conn = connection(client_id)
      conn.deliver(message)
    end
    
    def on_disconnect(client_id)
      conn = @connections[client_id]
      destroy_connection(conn)
    end
    
    def connection(id)
      return @connections[id] if @connections.has_key?(id)
      connection = Connection.new(id, @options)
      connection.add_subscriber(:stale_connection, method(:destroy_connection))
      @connections[id] = connection
    end
    
    def destroy_connection(connection)
      return unless connection
      connection.flush!
      connection.remove_subscribers
      @connections.delete(connection.id)
    end
    
    def accept_connection(options, response, socket, &callback)
      connection = connection(response['clientId'])
      connection.connect(options) do |events|
        callback.call([response] + events)
      end
    end
    
  public
    
    def flush_connection(messages)
      [messages].flatten.each do |message|
        connection = @connections[message['clientId']]
        connection.flush! if connection
      end
    end
    
    def process(messages, local_or_remote = false, &callback)
      socket = local_or_remote.is_a?(WebSocket) ? local_or_remote : nil
      local  = (local_or_remote == true)
      
      messages = [messages].flatten
      processed, responses = 0, []
      
      gather_replies = lambda do |replies|
        responses.concat(replies)
        processed += 1
        callback.call(responses.compact) if processed == messages.size
      end
      
      handle_reply = lambda do |replies|
        extended, expected = 0, replies.size
        gather_replies.call(replies) if expected == 0
        
        replies.each_with_index do |reply, i|
          pipe_through_extensions(:outgoing, reply) do |message|
            replies[i] = message
            extended  += 1
            gather_replies.call(replies) if extended == expected
          end
        end
      end
      
      messages.each do |message|
        pipe_through_extensions(:incoming, message) do |piped_message|
          handle(piped_message, socket, local, &handle_reply)
        end
      end
    end
    
    def make_response(message)
      response = {}
      %w[id clientId channel error].each do |field|
        if message[field]
          response[field] = message[field]
        end
      end
      response['successful'] = !response['error']
      response
    end
    
    def handle(message, socket = nil, local = false, &callback)
      return callback.call([]) if !message
      
      @engine.publish(message) unless message['error']
      channel_name = message['channel']
      
      if Channel.meta?(channel_name)
        handle_meta(message, socket, local, &callback)
      elsif message['clientId'].nil?
        callback.call([])
      else
        response = make_response(message)
        response['successful'] = !response['error']
        callback.call([response])
      end
    end
    
    def handle_meta(message, socket, local, &callback)
      method = Channel.parse(message['channel'])[1]
      
      __send__(method, message, local) do |response|
        advize(response)
        
        if response['channel'] == Channel::CONNECT and response['successful'] == true
          accept_connection(message['advice'], response, socket, &callback)
        else
          callback.call([response])
        end
      end
    end
    
    def advize(response)
      connection = response['clientId'] && connection(response['clientId'])
      
      advice = response['advice'] ||= {}
      if connection
        advice['reconnect'] ||= 'retry'
        advice['interval']  ||= (connection.interval * 1000).floor
        advice['timeout']   ||= (connection.timeout * 1000).floor
      else
        advice['reconnect'] ||= 'handshake'
      end
    end
    
    # MUST contain  * version
    #               * supportedConnectionTypes
    # MAY contain   * minimumVersion
    #               * ext
    #               * id
    def handshake(message, local = false, &callback)
      response = make_response(message)
      response['version'] = BAYEUX_VERSION
      
      response['error'] = Error.parameter_missing('version') if message['version'].nil?
      
      client_conns = message['supportedConnectionTypes']
      
      unless local
        response['supportedConnectionTypes'] = CONNECTION_TYPES
        
        if client_conns
          common_conns = client_conns.select { |c| CONNECTION_TYPES.include?(c) }
          response['error'] = Error.conntype_mismatch(*client_conns) if common_conns.empty?
        else
          response['error'] = Error.parameter_missing('supportedConnectionTypes')
        end
      end
      
      response['successful'] = response['error'].nil?
      return callback.call(response) unless response['successful']
      
      @engine.create_client do |client_id|
        response['clientId'] = client_id
        callback.call(response)
      end
    end
    
    # MUST contain  * clientId
    #               * connectionType
    # MAY contain   * ext
    #               * id
    def connect(message, local = false, &callback)
      response        = make_response(message)
      client_id       = message['clientId']
      connection_type = message['connectionType']
      
      @engine.client_exists(client_id) do |exists|
        response['error'] = Error.client_unknown(client_id) unless exists
        response['error'] = Error.parameter_missing('clientId') if client_id.nil?
        response['error'] = Error.parameter_missing('connectionType') if connection_type.nil?
        
        response['successful'] = response['error'].nil?
        response.delete('clientId') unless response['successful']
        
        @engine.ping(client_id) if response['successful']
        callback.call(response)
      end
    end
    
    # MUST contain  * clientId
    # MAY contain   * ext
    #               * id
    def disconnect(message, local = false, &callback)
      response   = make_response(message)      
      client_id  = message['clientId']
      
      @engine.client_exists(client_id) do |exists|
        response['error'] = Error.client_unknown(client_id) unless exists
        response['error'] = Error.parameter_missing('clientId') if client_id.nil?
        
        response['successful'] = response['error'].nil?
        response.delete('clientId') unless response['successful']
        
        @engine.destroy_client(client_id) if response['successful']
        callback.call(response)
      end
    end
    
    # MUST contain  * clientId
    #               * subscription
    # MAY contain   * ext
    #               * id
    def subscribe(message, local = false, &callback)
      response     = make_response(message)
      client_id    = message['clientId']
      subscription = [message['subscription']].flatten
      
      @engine.client_exists(client_id) do |exists|
        response['error'] = Error.client_unknown(client_id) unless exists
        response['error'] = Error.parameter_missing('clientId') if client_id.nil?
        response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?
        
        response['subscription'] = subscription.compact
        
        subscription.each do |channel|
          next if response['error']
          response['error'] = Error.channel_forbidden(channel) unless local or Channel.subscribable?(channel)
          response['error'] = Error.channel_invalid(channel) unless Channel.valid?(channel)
          
          next if response['error']
          @engine.subscribe(client_id, channel)
        end
        
        response['successful'] = response['error'].nil?
        callback.call(response)
      end
    end
    
    # MUST contain  * clientId
    #               * subscription
    # MAY contain   * ext
    #               * id
    def unsubscribe(message, local = false, &callback)
      response     = make_response(message)
      client_id    = message['clientId']
      subscription = [message['subscription']].flatten
      
      @engine.client_exists(client_id) do |exists|
        response['error'] = Error.client_unknown(client_id) unless exists
        response['error'] = Error.parameter_missing('clientId') if client_id.nil?
        response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?
        
        response['subscription'] = subscription.compact
        
        subscription.each do |channel|
          next if response['error']
          response['error'] = Error.channel_forbidden(channel) unless local or Channel.subscribable?(channel)
          response['error'] = Error.channel_invalid(channel) unless Channel.valid?(channel)
          
          next if response['error']
          @engine.unsubscribe(client_id, channel)
        end
        
        response['successful'] = response['error'].nil?
        callback.call(response)
      end
    end
    
  end
end

