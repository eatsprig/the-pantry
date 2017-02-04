module Pantry
  class DryGood < OpenStruct
    include ActiveModel::Serialization

    # Implements required interface method for ActiveModel::Serialization.
    def attributes
      to_h.deep_stringify_keys
    end

    def ==(other)
      super
    end

    def hash
      super
    end

    # OpenStruct objects don't turn into hashes wrapped in a 'table' key
    # http://goo.gl/vPjtgz
    def as_json(options = nil)
      @table.as_json(options)
    end

    alias_method :eql?, :==
  end
end
