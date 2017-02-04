module Pantry
  module Stocked
    extend ActiveSupport::Concern

    @@includers = []

    def self.includers
      @@includers
    end

    included do
      @@includers << self
      after_commit -> (record) { self.class.invalidate(record) }
    end

    module ClassMethods

      def local_key_prefix
        to_s.downcase
      end

      def local_key_version
        1
      end

      def key_ttl_s
        Pantry.configuration.global_key_ttl_s
      end

      def restock?
        false
      end

      # Allows the client (the includer of this module) to declare a secondary
      # index on the given attribute.
      #
      # @param attribute [Symbol, String] attribute to stock by, should be an
      #   attribute of the Class
      # @param unique [Boolean, nil] Whether or not the declared index is
      #   unique.
      # @param &block [Block] The block should behave like a block you'd use
      #   in a `scope`. It should expect to be chained on to an existing
      #   scoping chain, and should return a scope.
      #   Ex. stock_by(:team) { where.not(nickname: "Benji") }
      def stock_by(attribute, unique: false, &block)
        secondary_indices[attribute.to_sym] = {
          unique: !!unique,
          block: block
        }
      end

      # Retrieves a single object, looking first to the cache and then to the
      # database.
      #
      # @param id [Integer] Unique identifier of the desired object.
      # @return [DryGood] Cached object. This object will have accessors for
      #   all the attributes returned by `pantry_attributes`.
      def get(id)
        multi_get([id])[id]
      end

      # Retrieves a single object by the value of an indexed attribute.
      #
      # @param attribute [String, Symbol] Name of indexed attribute.
      # @param value [String] Stringified value of the indexed attribute for
      #   which to fetch the result.
      # @return [DryGood] Cached object.
      def get_by(attribute, value)
        multi_get_by(attribute, [value])[value]
      end

      # Retrieves multiple objects, looking first to the cache and then to the
      # database.
      #
      # @param ids [Array<Integer>] Unique identifiers of the desired objects.
      # @return [Hash<Integer, DryGood>] Map from object identifier to cached
      #   object.
      def multi_get(ids)
        cached_records = multi_fetch(ids)

        misses = cached_records.reduce([]) do |memo, (id, cached)|
          memo << id unless cached
          memo
        end

        db_records = misses.any? ? multi_store(where(id: misses).all.to_a) : {}

        ids.reduce({}) do |memo, id|
          memo[id] = cached_records[id] || db_records[id.to_i]
          memo
        end
      end

      # Retrieves a multiple objects by the values of an indexed attribute.
      #
      # @param attribute [String, Symbol] Name of indexed attribute.
      # @param values [Array<String>] Stringified values of the indexed
      #   attribute for which to fetch the results.
      # @return [Hash<String, DryGood>] Map from attribute value to cached
      #   object.
      def multi_get_by(attribute, values)
        cached_records = multi_fetch_by(attribute, values)

        misses = []

        empty_values = cached_records.reduce([]) do |memo, (val, cached)|
          memo << val if cached.blank?
          memo
        end

        if empty_values.any?
          existences = Pantry.redis.pipelined do
            empty_values.map do |val|
              Pantry.redis.exists(secondary_index_cache_key(attribute, val))
            end
          end

          empty_values.zip(existences).each do |(val, exists)|
            unless exists
              # Explicitly mark the cache miss (since otherwise, i.e. when the
              # index key exists, an empty array is a valid cache response).
              cached_records[val] = nil

              misses << val
            end
          end
        end

        db_records = multi_store_by(attribute, misses)

        values.reduce({}) do |memo, val|
          memo[val] = cached_records[val] || db_records[val]
          memo
        end
      end

      # Retrieves all cached objects for this model class.
      #
      # This method should be used with caution: it may have negative
      # performance consequences if used to retrieve large collections. It is
      # intended for use on small collections that are important to business
      # logic but that do not change often. Additionally, method will only work
      # reliably if `restock?` is set to return `true`.
      #
      # @return [Hash<Integer, DryGood>] Map from object identifier to cached
      #   object.
      def multi_get_all
        unless restock?
          fail ConfigurationError.new(
            "restock?() must return true in order to use multi_get_all()")
        end

        if Pantry.configuration.force_cache_misses
          result = all.reduce({}) do |memo, obj|
            memo[obj.id] = DryGood.new(JSON.parse(obj.send(:pantry_json)))
            memo
          end
          return result
        end

        keys = Pantry.redis.zrangebyscore(
          all_index_cache_key,
          Time.now.to_i,
          "+inf")
        if keys.empty?
          restock!
        else
          multi_fetch(keys.map(&:to_i))
        end
      end

      # Invalidates a single cache entry.
      #
      # @param obj_or_id [Object, Integer] Object (or primary key identifier for
      #   the object) whose cache entry we should delete.
      def invalidate(obj_or_id)
        multi_invalidate([obj_or_id])
      end

      # Invalidates a series of cache entries.
      #
      # @param objects_or_ids [Array<Object>, Array<Integer>] Objects (or
      #   primary key identifiers for objects) whose cache entries we should
      #   delete.
      def multi_invalidate(objects_or_ids)
        return if objects_or_ids.empty?

        is_integer_list = objects_or_ids.first.is_a?(Integer)

        objects = objects_or_ids
        if is_integer_list && (secondary_indices.any? || restock?)
          objects = where(id: objects_or_ids).all.to_a
        end

        Pantry.redis.del(
          objects_or_ids.map { |o| cache_key(is_integer_list ? o : o.id) })

        if secondary_indices.any?
          invalidate_secondary_indices(objects)
        end

        if restock?
          # TODO(lerebear): Make multi_store take optional list of cache keys.
          # Store anything that we haven't already.
          multi_store(
            objects.find_all { |obj| !obj.destroyed? },
            skip_deserialization: true)
        end

        nil
      end

      # We invalidate a key if either of the following is true:
      #   - The attribute is stocked conditionally (indicated by the presence
      #     of a block option)
      #   - The given objects' attributes that are indexed have changed. In
      #     this case we invalidate both the old and new values for the indexed
      #     attribute
      #
      # @param objects [Array<Object>]
      def invalidate_secondary_indices(objects)
        objects_by_dirty_index = secondary_indices
          .reduce({}) do |memo, (attribute, options_hash)|
          has_block = options_hash[:block]

          if has_block
            memo[attribute] = objects
          else
            dirty_objects = objects.find_all do |obj|
              !obj.destroyed? && obj.previous_changes[attribute.to_s].present?
            end

            if dirty_objects.any?
              memo[attribute] = dirty_objects
            end
          end

          memo
        end

        Pantry.redis.pipelined do
          objects_by_dirty_index.each do |attribute, dirty_objs|
            # Invalidate attribute indices.
            dirty_objs.each do |o|
              (o.previous_changes[attribute.to_s] || [o.send(attribute)])
                .each do |val|

                Pantry.redis.del(secondary_index_cache_key(attribute, val))
              end
            end
          end
        end
      end

      # Writes all objects for the model class to the cache.
      #
      # This is a utility method for ensuring that the cache is populated for
      # classes that wish to use the `multi_get_all` functionality`. This method
      # will only write to the cache if `restock?` is set to return
      # `true`.
      #
      # @return [Hash<Integer, DryGood>, Nil] Map from object identifier to
      #   cached object, or nil if no objects were written to the cache.
      def restock!
        multi_store(all.to_a) if restock?
      end

      # Clears all expired entries from index keys.
      #
      # Entries in an index will never expire unless you call this method. That
      # should be fine in most cases, and it never affects correctness (because
      # only non-expired keys are returned by `multi_get_all`). However, this
      # method can be used to address the concern of the values of index keys
      # growing too big.
      #
      # @return [Integer, Nil] The number of elements that were expired, or nil
      #   if we aren't using indices.
      def tidy!
        # TODO(lerebear): This is no good because you have to call restock!
        # alongside this to guarantee correctness. Better idea is probably to
        # just have a clean! method that does both tidy! and restock! for the
        # all_index_cache_key, and also removes all other attribute index cache
        # keys at the same time (those will regenerate on the fly). Then make
        # clear in the docs that you can use clean! on a schedule to help
        # maintain your cache.
        Pantry.redis.zremrangebyscore(all_index_cache_key, 0, Time.now.to_i - 1)
      end

      # Provides a hook for mixers to implement to provide a more specific
      # class to instantiate when de-serializing from the cache.
      #
      # The returned class should quack like `OpenStruct#new`
      #
      # @return [Class]
      def dry_good_type
        DryGood
      end

      # Provides a hook for mixers to do pre-processing on the given
      # objects to improve serialization performance.
      #
      # @param objects [Array<ActiveRecord::Base>] the objects fetched from the
      #   database on a cache miss
      def before_pantry_serialize(objects)
      end

      private

      def secondary_indices
        @indices ||= {}
      end

      def fetch(id)
        multi_fetch([id])[id]
      end

      def multi_fetch(ids)
        return Hash[ids.zip([nil])] if Pantry.configuration.force_cache_misses

        keys = ids.map { |id| cache_key(id) }
        cached = keys.length > 0 ? Pantry.redis.mget(keys) : []
        ids.zip(cached).reduce({}) do |memo, (id, retrieved)|
          memo[id] = retrieved && restore_deserialized(JSON.parse(retrieved))
          memo
        end
      end

      def multi_fetch_by(attribute, values)
        is_unique_index = secondary_indices[attribute.to_sym].try(:[], :unique)

        if Pantry.configuration.force_cache_misses
          return values.reduce({}) do |memo, val|
            memo[val] = is_unique_index ? nil : []
            memo
          end
        end

        # TODO(lerebear): Create a pipelining helper to avoid pipeline cost for
        # lists of 1.
        id_lists = Pantry.redis.pipelined do
          values.map do |val|
            Pantry
              .redis
              .smembers(secondary_index_cache_key(attribute, val))
          end
        end

        id_lists = id_lists.map { |ids| ids.map(&:to_i) }
        cached = multi_get(id_lists.flatten)

        values.zip(id_lists).reduce({}) do |memo, (val, ids)|
          memo[val] = \
            if is_unique_index
              ids.first && cached[ids.first]
            else
              ids.reduce([]) do |acc, id|
                if (retrieved = cached[id])
                  acc << retrieved
                end
                acc
              end
            end
          memo
        end
      end

      def restore_deserialized(attrs)
        cast_attributes(dry_good_type.send(:new, attrs))
      end

      def cast_attributes(dry_good)
        columns_hash.find_all { |_, hash| hash.type.to_s == "datetime" }
          .map(&:first)
          .each do |attr|
          if (value = dry_good.send(attr)) && value.is_a?(String)
            dry_good.send("#{attr}=", Time.parse(value))
          end
        end
        dry_good
      end

      def store(id, skip_deserialization: false)
        cached = multi_store(
          where(id: id).all.to_a,
          skip_deserialization: skip_deserialization)
        cached[id] unless skip_deserialization
      end

      def multi_store(objects, skip_deserialization: false)
        return {} if objects.empty?

        before_pantry_serialize(objects)
        object_ids = []
        to_cache = {}
        objects.each do |obj|
          object_ids << obj.id
          to_cache[cache_key(obj.id)] = obj.send(:pantry_json)
        end

        Pantry.redis.pipelined do
          Pantry.redis.mset(*to_cache.flatten)
          object_ids.each do |id|
            Pantry.redis.expire(cache_key(id), key_ttl_s)
          end

          # Add to "all" index key if necessary.
          now = Time.now.to_i
          if restock?
            Pantry.redis.zadd(
              all_index_cache_key,
              object_ids.map { |id| [now + key_ttl_s, id] })
          end
        end

        unless skip_deserialization
          # HACK(lerebear): Incurring the JSON parsing cost here is really bad.
          # Ideally we would just return `pantry_attributes` of every object. The
          # problem is that the hash returned by `pantry_attributes` still
          # contains unserialized types (e.g. Date, which gets serialized to a
          # string when written to the cache and so emerges from the cache as a
          # string). That creates problems in tests and, conceptually, this should
          # return the same sort of object as `multi_fetch`, so the workaround is
          # to just parse the JSON.
          to_cache.values.reduce({}) do |memo, obj|
            restored = restore_deserialized(JSON.parse(obj))
            memo[restored.id] = restored
            memo
          end
        end
      end

      def multi_store_by(attribute, values, skip_deserialization: false)
        return {} if values.empty?

        is_unique_index = secondary_indices[attribute.to_sym].try(:[], :unique)
        block = secondary_indices[attribute.to_sym].try(:[], :block)

        scope = where(attribute.to_sym => values)

        if block
          scope = scope.scoping { block.call }
        end

        objects_by_attribute_value ||= \
          scope
            .all
            .group_by { |obj| obj.send(attribute) }

        Pantry.redis.pipelined do
          # Populate secondary indices.
          objects_by_attribute_value.each do |value, objs|
            Pantry.redis.sadd(
              secondary_index_cache_key(attribute, value),
              objs.map(&:id))
          end
        end
        # Also populate primary index (since we have the objects handy).
        multi_store(
          objects_by_attribute_value.values.flatten.sort_by(&:id),
          skip_deserialization: true)

        unless skip_deserialization
          # HACK(lerebear): Same hack as in `multi_store` method above.
          values.reduce({}) do |memo, val|
            objs = objects_by_attribute_value[val] || []
            memo[val] = \
              if is_unique_index
                objs.first && restore_deserialized(
                  JSON.parse(objs.first.send(:pantry_json)))
              else
                objs.map do |o|
                  restore_deserialized(JSON.parse(o.send(:pantry_json)))
                end
              end
            memo
          end
        end
      end

      def cache_key(id)
        [
          Pantry.configuration.global_key_prefix,
          "v#{Pantry.configuration.global_key_version}",
          local_key_prefix,
          "v#{local_key_version}",
          "##{id}"
        ].join(":")
      end

      def secondary_index_cache_key(attribute, value)
        [
          Pantry.configuration.global_key_prefix,
          "v#{Pantry.configuration.global_key_version}",
          local_key_prefix,
          "v#{local_key_version}",
          "index",
          attribute,
          value.nil? ? "__pantry_nil__" : value
        ].join(":")
      end

      def all_index_cache_key
        secondary_index_cache_key(:id, "all")
      end
    end

    # @return [Hash] Attributes to cache.
    def pantry_attributes
      attributes
    end

    private

    def pantry_json
      pantry_attributes.to_json
    end
  end
end
