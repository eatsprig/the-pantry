# Pantry

Pantry provides ActiveRecord model caching in Redis via a mixin. **Before you go to the store, check the pantry!**

Pantry strives to be simple and intuitive. Its philosophy is that a cache should be dumb. You should use a cache to perform basic queries quickly; you should not use it to mimic a relational database. As a result, the query API that Pantry exposes is small and straightforward.

## Features

+ Retrieval of a single object from the cache by primary key.
+ Retrieval of multiple objects from the cache by list of primary keys.
+ Retrieval of all cached objects for a model in one fell swoop.
+ Global and model-specific cache invalidation via configuration.
+ Specification of cached object attributes via configuration.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'the-pantry', require: 'pantry'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install the-pantry

## Usage

You can enable caching on your ActiveRecord model by mixing in `Pantry::Stocked`.

Basic example:
```ruby
class User
  include Pantry::Stocked
end
```

Full example:
```ruby
module UserMethods
  def full_name
    "#{first_name} #{last_name}".strip
  end
end

module Cache
  class User < Pantry::DryGood
    include UserMethods
  end
end

class User
  include Pantry::Stocked
  include UserMethods
  
  stock_by :email
  
  class << self
    def local_key_version
      123
    end

    def dry_good_type
      Cache::User
    end
  end

  def pantry_attributes
    super.merge(
      "profile_photo_url" => profile_photo.url
    )
  end
end

user = User.find(1) #=> ActiveRecord::Base
user.full_name #=> Dude Guy
user.profile_photo.url #=> https://mybucket.s3.amazonaws.com/users/profile_photos/001/me.png

user = User.get(1) #=> Pantry::DryGood
user.full_name #=> Dude Guy
user.profile_photo_url #=> https://mybucket.s3.amazonaws.com/users/profile_photos/001/me.png
```

The following methods will be added to the `User` class:

#### `User.get(id)`

Retrieves a single object, looking first to the cache and then to the database.

#### `User.get_by(attribute_name, attribute_value)`

Retrieves a single object by the value of one of its attributes, looking first to the cache and then to the database. In order to use this method, the model must declare `stock_by` with the desired attribute name.

#### `User.multi_get(ids)`

Retrieves multiple objects, looking first to the cache and then to the database.

#### `User.multi_get_by(attribute_name, attribute_values)`

Retrieves multiple objects by the given list of values for a single attribute. Looks first to the cache and then to the database.

#### `User.multi_get_all`

Retrieves all the objects that exist in the cache. Unlike other methods, this method does not fall back to the database unless the cache for the model in question is completely empty. The `restock?` configuration method (described below) must return `true` in order to use this method.

#### `User.invalidate(id)`

Removes a single entry from the cache.

#### `User.multi_invalidate(ids)`

Removes multiple entries from the cache.

#### `User.restock!`

Writes all model objects to the cache. This is mainly for use in conjunction with models that want to use the `multi_get_all` functionality. This is potentially very expensive, so it should be used with caution.

#### `User.tidy!`

Clears all expired entries from the index key used to serve `multi_get_all` requests. Never calling this method will not affect correctness (i.e. expired entries will never be returned from the index), but your index will grow indefinitely.

## Model Configuration

You can customize the behaviour of the cache by overriding a few configuration options:

Example:
```ruby
class User
  include Pantry::Stocked

  def self.local_key_prefix
    "my_application_specific_prefix"
  end

  def self.restock?
    true
  end

  def pantry_attributes
    {
        "id": id,
        "nickname": nickname
    }
  end
end
```

#### `User.local_key_prefix`

Returns the portion of the cache key that is specific to this model. Defaults to the lower-cased class name.

#### `User.local_key_version`

Returns the cache key version of cache objects for this model. Defaults to `1`.

#### `User.key_ttl_s`

Returns the TTL for cache keys for this model. Defaults to the `Pantry.global_key_ttl_s` value (which, by default, is 1 week).

#### `User.restock?`

Returns a boolean indicating whether or not the cache should be eagerly re-populated with a record after a change to that record was committed. This method must be configured to return `true` in order to use the `multi_get_all` method. Defaults to `false`.

#### `User.dry_good_type`

Allows for specifying a class to instantiate when an object is de-serialized from cache. The returned class should quack like `OpenStruct.new` and accept the attributes returned by `pantry_attributes`. This defaults to `Pantry::DryGood`.

#### `User#pantry_attributes`

Returns a hash of attributes to write to the cache.

#### `User.stock_by(attribute_name, unique: false)`

Adds a secondary cache index for the given attribute. This enables the use of `get_by` and `multi_get_by`. The `unique` flag specifies whether or not to create a unique index.

## Global Configuration

Finally, there are global configuration options that you can set on the `Pantry.configuration` hash to manage configuration across all cached models:

```ruby
# config/initializers/pantry.rb

Pantry.configuration.redis_uri          = "some-redis-host.com:12345" # defaults to "localhost:6379"
Pantry.configuration.global_key_prefix  = "myapp"                     # defaults to "pantry"
Pantry.configuration.global_key_version = 123                         # defaults to 1
Pantry.configuration.global_key_ttl_s   = 30.days                     # defaults to 1 week
Pantry.configuration.force_cache_misses = true                        # defaults to false
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake rspec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. 

To release a new version:
+ Update the version number in `lib/pantry/version.rb`
+ `git tag -a -m "Version <VERSION_NUMBER>" v<VERSION_NUMBER>`

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

