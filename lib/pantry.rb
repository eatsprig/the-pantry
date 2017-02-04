require "active_record"
require "hiredis"
require "json"
require "ostruct"
require "redis"

require "pantry/version"
require "pantry/configuration_error"
require "pantry/dry_good"
require "pantry/stocked"

module Pantry
  class << self
    # Returns the (mutable) configuration object for this module.
    #
    # The following keys are supported:
    #   :redis_uri - The Redis instance to use as the cache. Defaults to nil,
    #     which in turn allows the Redis library to connect to the default host.
    #   :global_key_prefix - The portion of the cache key prefix that should be
    #     used for all cache keys. Defaults to `pantry`.
    #   :global_key_version - The key version to use for all cache keys.
    #     Defaults to `1`.
    #   :global_key_ttl_s - The default TTL (in seconds) to apply to all keys.
    #     Defaults to 1 week.
    #   :force_cache_misses - Whether or not to ignore the cache completely on
    #     read. Defaults to false.
    # @return [OpenStruct] Configuration object.
    def configuration
      @configuration ||= OpenStruct.new(
        redis_uri: nil,
        global_key_prefix: "pantry",
        global_key_version: 1,
        global_key_ttl_s: 60 * 60 * 24 * 7 * 2,
        force_cache_misses: false)
    end

    # Returns the redis instance that this module is using as a cache.
    #
    # @return [Redis] Redis instance.
    def redis
      @redis ||= Redis.new(
        url: Pantry.configuration.redis_uri,
        driver: :hiredis)
    end
  end
end
