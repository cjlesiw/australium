require 'yaml'

module Australium

  # Allows access to events in an Australium database.
  # Unlike a direct Sequel connection, the EventCache will return a fully-formed Event object.
  class EventCache
    class << self
      private
      def event_filter(event_name, event_class)
        define_method(event_name) { @db[event_class.name.split('::').last.to_sym] }
      end
    end
    include EventFilters

    attr_accessor :db

    # Creates a new instance of EventCache.
    # @param [Sequel::Database] db
    def initialize(db)
      @db = db
    end

    # Returns true if this game's data has been cached.
    # @param [Fixnum] game_hash hash of a game_log
    # @return [TrueClass] whether or not the data from this game_log has been cached
    def has_game?(game_hash)
      @db[:MapLoad].where(:game_id => game_hash).count > 0 rescue false
    end

    # Passes a block to the database object and returns reconstructed Events.
    # @param [Proc] block the queries to act on the database object
    # @return [Array<Event>] the reconstructed Event object or objects, if reconstruction was successful
    def query(&block)
      events = instance_exec(&block)

      # Raise an exception if results are not in the expected format.
      raise CacheReadError unless events.is_a?(Sequel::Dataset)

      # Cycle through each result and transform it from a Sequel::Dataset into an Event.
      begin
        event_class = Australium.const_get(events.first_source_table)
      rescue NameError => e
        raise CacheReadError.new(e)
      end

      events = events.to_a

      # Convert to hash and unserialize serialized objects.
      events.map! do |event|
        event.map do |key, value|
          begin
            if value.is_a?(String)
              new_value = YAML::load(value)
              value = new_value if new_value.is_a?(OpenStruct)
            end
          rescue ; nil end
          [key, value]
        end.to_h
      end

      events.map { |event| event_class.new(event) }
    end

    # Caches a complete {Game}.
    # @param [Australium::Game] game game to be added to the cache
    def store(game)

      data = Hash.new { |h, k| h[k] = [] }

      # If a MapLoad event exists with identical parameters for everything except the game hash, delete the previous
      # game data - as this indicates an invalid or incomplete log was stored.
      if @db.tables.include?(:MapLoad)
        event = game.map_loads.first
        matches = db[:MapLoad].where(
          :server => event.server,
          :timestamp => event.timestamp
        )
        matches.each do |match|
          puts "Removing data from game #{match[:game_id]} as an incomplete cache."
          invalid_game = match[:game_id]
          @db.tables.each do |table|
            @db[table].where(:game_id => invalid_game).delete
          end
        end
      end

      # Keep the database state in memory to avoid querying for the state while inside loops.
      db_state = {}
      @db.tables.each do |table|
        db_state[table] = @db[table].columns
      end

      game.events.each do |event|
        table = event.class.to_s.split('::').last.to_sym

        unless db_state.keys.include?(table)
          @db.create_table(table) do
            primary_key :id
            String :game_id, :index => true
            String :server, :index => true
            Fixnum :line_number, :index => true
            DateTime :timestamp, :index => true
          end
          db_state[table] = @db[table].columns
        end

        event = event.to_h

        # Due to the enormous amount of repeated information, saving GameState objects is not a sane proposition at
        # this time. Until GameState objects can be stored more efficiently, they will not be inserted into databases.
        event.delete(:state)

        event.each_pair do |key, value|
          event[key] = value.to_yaml if value.is_a?(OpenStruct)
          value = event[key]

          unless db_state[table].include?(key.to_sym) || value.nil?
            @db.alter_table(table) { add_column key.to_sym, value.class }
            db_state[table] << key.to_sym
          end
        end

        data[table] << event
      end

      # Enter data into the database.
      # For #multi_insert to function properly, all rows must contain the same keys.
      data.each_pair do |table, rows|
        all_columns = rows.map { |r| r.keys }.flatten.uniq

        rows.each do |row|
          all_columns.each { |c| row[c] = nil unless row.has_key?(c) }
        end

        @db[table].multi_insert(rows)
      end

    end

  end

end
