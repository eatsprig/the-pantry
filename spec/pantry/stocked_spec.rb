require "spec_helper"
require "support/schema"
require "support/typical_model"

describe Pantry::Stocked do
  let(:redis) { Pantry.redis }
  let(:instance) do
    TypicalModel.create!(name: "Olalere", nickname: "Lere", team: "backend")
  end
  let(:cache_key) { TypicalModel.send(:cache_key, instance.id) }
  let(:instances) do
    [
      TypicalModel.create!(name: "Matthew", nickname: "Matt", team: "backend"),
      TypicalModel.create!(name: "Kyle", nickname: "Kyle", team: "client"),
      TypicalModel.create!(name: "Olalere", nickname: "Lere", team: "backend"),
      TypicalModel.create!(name: "Benjamin", nickname: "Benji", team: "backend")
    ]
  end

  context "after_commit" do
    before { redis.set(cache_key, instance.send(:pantry_json)) }

    it "should invalidate the cache" do
      expect(TypicalModel)
        .to receive(:invalidate)
        .with(instance)
      instance.run_callbacks(:commit)
    end

    context "on destroy with restock" do
      before do
        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)
      end

      it "should not restock the model" do
        expect(TypicalModel).to_not receive(:store)
        instance.destroy!
      end
    end
  end

  describe ".multi_get" do
    let(:result) { TypicalModel.multi_get(instances.map(&:id)) }

    context "for a mixture of cache hits and misses" do
      before do
        # Make sure even numbered ids are cached and odd ones are not cached.
        instances.each do |obj|
          cache_key = TypicalModel.send(:cache_key, obj.id)
          if obj.id.even?
            redis.set(cache_key, obj.send(:pantry_json))
          else
            redis.del(cache_key)
          end
        end
      end

      it "should fill in misses in returned results" do
        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(result).to eq(expected)
      end

      it "should write misses to the cache" do
        uncached = instances.find_all { |obj| obj.id.odd? }
        multi_store_response = uncached
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(TypicalModel)
          .to receive(:multi_store)
          .with(uncached)
          .and_return(multi_store_response)
        result
      end

      it "casts times to Time objects" do
        expect(result.values.first.created_at).to be_a(Time)
      end
    end

    context "on cache miss" do
      before do
        instances
        redis.flushall
      end

      context "when ids are provided as strings" do
        let(:result) { TypicalModel.multi_get([instance.id.to_s]) }

        it "returns strings (not integers) as keys in the result" do
          expect(result).to eq({
            instance.id.to_s => Pantry::DryGood.new(
              JSON.parse(instance.send(:pantry_json)))
          })
        end
      end
    end
  end

  describe ".multi_get_by" do
    context "for a non-unique index" do
      let(:expected) do
        {
          "backend" => [instances[0], instances[2], instances[3]]
            .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) },
          "infrastructure" => []
        }
      end
      let(:result) do
        TypicalModel.multi_get_by(
          :team,
          ["backend", "infrastructure"])
      end

      # Make sure instances exist. This also triggers indexing via the
      # invalidation that occurs after commit.
      before { instances }

      context "when index is fully populated" do
        it "retrieves indexed records" do
          expect(result).to eq(expected)
        end

        context "when a new record is created" do
          let(:new_instance) do
            TypicalModel.create!(name: "Remi",
                                 nickname: "Remi",
                                 team: "backend")
          end

          before do
            # Load some records into the cache
            TypicalModel.multi_get_by(
              :team,
              ["backend", "infrastructure"])
            # create the new record
            new_instance
          end

          it "updates index to include new record" do
            expect(result["backend"])
              .to include(Pantry::DryGood.new(
                JSON.parse(new_instance.send(:pantry_json))))
          end
        end
      end

      context "when index is not populated" do
        let(:backend_team_index_key) do
          TypicalModel.send(:secondary_index_cache_key, :team, "backend")
        end

        before { redis.del(backend_team_index_key) }

        it "retrieves relevant records" do
          expect(result).to eq(expected)
        end

        it "fills in the index as necessary" do
          result
          expect(redis.smembers(backend_team_index_key).sort)
            .to eq(expected["backend"].map { |obj| obj.id.to_s })
        end

        context "when a block was given for the attribute" do
          let(:expected) do
            {
              "backend" => [instances[0], instances[2]]
                .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) },
              "infrastructure" => []
            }
          end

          before do
            TypicalModel.class_eval do
              stock_by(:team) { where.not(nickname: "Benji") }
            end
          end

          after do
            TypicalModel.class_eval { stock_by(:team) }
          end

          it "uses the block to further scope fetching from the database" do
            expect(result).to eq(expected)
          end

          context "when a record is updated that removes it from the scope" do
            let(:expected) do
              {
                "backend" => [instances[0]]
                  .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) },
                "infrastructure" => []
              }
            end

            before do
              # fetch before we make the change to load all instances
              result = TypicalModel.multi_get_by(
                :team,
                ["backend", "infrastructure"])
              instances[2].update!(nickname: "Benji")
            end

            it "properly invalidates and then refetches correct objects" do
              expect(result).to eq(expected)
            end
          end
        end
      end
    end

    context "for a unique index" do
      let(:expected) do
        expected = [instances[0], instances[2]]
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:nickname)
        expected["Jes"] = nil
        expected
      end
      let(:result) do
        TypicalModel.multi_get_by(:nickname, ["Lere", "Matt", "Jes"])
      end

      # Make sure instance exists. This also triggers indexing via the
      # invalidation that occurs after commit.
      before { instances }

      context "when index is fully populated" do
        it "retrieves indexed records" do
          expect(result).to eq(expected)
        end
      end

      context "when index is only partially populated" do
        let(:nickname_key) do
          TypicalModel.send(:secondary_index_cache_key, :nickname, "Lere")
        end

        before { redis.del(nickname_key) }

        it "retrieves relevant records" do
          expect(result).to eq(expected)
        end

        it "fills in the index as necessary" do
          result
          expect(redis.scard(nickname_key)).to eq(1)
        end
      end
    end
  end

  describe ".get" do
    let(:result) { TypicalModel.get(instance.id) }

    before do
      expect(TypicalModel)
        .to receive(:multi_get)
        .with([instance.id])
        .and_return({
          instance.id => Pantry::DryGood.new(instance.pantry_attributes)
        })
    end

    it "should unpack the result of a multi_get" do
      expect(result).to eq(Pantry::DryGood.new(instance.pantry_attributes))
    end
  end

  describe ".get_by" do
    context "for a non-unique index" do
      let(:result) { TypicalModel.get_by(:team, "backend") }

      # Make sure instances exist. This also triggers indexing via the
      # invalidation that occurs after commit.
      before { instances }

      it "retrieves indexed records" do
        expected = [instances[0], instances[2], instances[3]]
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
        expect(result).to eq(expected)
      end

      context "when index entry exists but object has been deleted" do
        before { instances[0].destroy! }

        it "does not return that object" do
          expected = [instances[2], instances[3]].map do |obj|
            Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json)))
          end

          expect(result).to eq(expected)
        end
      end
    end

    context "for a unique index" do
      let(:result) { TypicalModel.get_by(:nickname, "Lere") }

      # Make sure instance exists. This also triggers indexing via the
      # invalidation that occurs after commit.
      before { instance }

      it "retrieves an indexed record" do
        expect(result).to eq(
          Pantry::DryGood.new(JSON.parse(instance.send(:pantry_json))))
      end

      context "when index entry exists but object has been deleted" do
        before { instance.destroy! }

        it "returns nil" do
          expect(result).to be_nil
        end
      end
    end
  end

  describe ".multi_get_all" do
    let(:now) { Time.now }
    let(:result) { TypicalModel.multi_get_all }

    before do
      # Configure the model to allow `multi_get_all`.
      allow(TypicalModel)
        .to receive(:restock?)
        .and_return(true)
    end

    context "with the index fully populated" do
      before do
        # Cache all the objects.
        instances.each do |obj|
          redis.set(
            TypicalModel.send(:cache_key, obj.id),
            obj.send(:pantry_json))
        end

        # Set up cache index.
        keys_with_scores = instances.map do |obj|
          if obj.id.even?
            # Not expired.
            [now.to_i + obj.class.key_ttl_s, obj.id]
          else
            # Expired.
            [now.to_i - 1, obj.id]
          end
        end
        redis.zadd(
          TypicalModel.send(:all_index_cache_key),
          keys_with_scores)

        Timecop.freeze(now)
      end

      after { Timecop.return }

      it "should fetch all cached models" do
        expected = instances
          .find_all { |obj| obj.id.even? }
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(result).to eq(expected)
      end
    end

    context "without an index key (equivalent to empty index key)" do
      before do
        instances
        redis.del(TypicalModel.send(:all_index_cache_key))
      end

      it "should fetch all models from the database" do
        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(result).to eq(expected)
      end

      it "should populate the index key" do
        expect {
          instances
          result
        }.to change {
          redis.zcard(TypicalModel.send(:all_index_cache_key))
        }.from(0).to(4)
      end
    end

    context "when configured to force cache misses" do
      before { Pantry.configuration.force_cache_misses = true }
      after { Pantry.configuration.force_cache_misses = false }

      it "should fetch all models (from the database)" do
        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(result).to eq(expected)
      end
    end
  end

  describe ".multi_fetch" do
    let(:result) { TypicalModel.send(:multi_fetch, instances.map(&:id)) }

    context "when configured to force cache misses" do
      before { Pantry.configuration.force_cache_misses = true }
      after { Pantry.configuration.force_cache_misses = false }

      it "should return a hash of only nil values" do
        expect(result.keys.sort).to eq(instances.map(&:id).sort)
        expect(result.values).to eq([nil] * instances.length)
      end
    end
  end

  describe ".multi_fetch_by" do
    context "when configured to force cache misses" do
      before { Pantry.configuration.force_cache_misses = true }
      after { Pantry.configuration.force_cache_misses = false }

      context "for a non-unique index" do
        let(:result) do
          TypicalModel.send(:multi_fetch_by, "team", instances.map(&:team).uniq)
        end

        it "should return a hash of only empty arrays" do
          teams = instances.map(&:team).uniq.sort
          expect(result.keys.sort).to eq(teams)
          expect(result.values).to eq([[]] * teams.length)
        end
      end

      context "for a unique index" do
        let(:result) do
          TypicalModel.send(
            :multi_fetch_by,
            "nickname",
            instances.map(&:nickname).uniq)
        end

        it "should return a hash of only empty nil values" do
          nicknames = instances.map(&:nickname).uniq.sort
          expect(result.keys.sort).to eq(nicknames)
          expect(result.values).to eq([nil] * nicknames.length)
        end
      end
    end
  end

  describe ".dry_good_type" do
    let(:result) { TypicalModel.get(instances.first.id) }

    context "when type is left as default" do
      it "should return a DryGood" do
        expect(result.class).to be(Pantry::DryGood)
      end
    end

    context "when class defines a dry_good_type method" do
      before do
        TypicalModel.singleton_class.send(:define_method,
                                          :dry_good_type,
                                          -> { TypicalModel })
      end

      after do
        TypicalModel.singleton_class.send(:remove_method, :dry_good_type)
      end

      it "should return the custom type" do
        expect(result.class).to be(TypicalModel)
      end
    end
  end

  describe ".multi_store" do
    let(:result) { TypicalModel.send(:multi_store, instances) }

    before do
      # Make sure the instances exist, so any caching that their creation
      # triggers is done up front.
      instances

      # Clear the cache.
      redis.flushall
    end

    it "should write keys to the cache" do
      expect {
        result
      }.to change {
        redis.mget(instances.map { |obj| obj.class.send(:cache_key, obj.id) })
      }.from([nil] * 4).to(instances.map { |obj| obj.send(:pantry_json) })
    end

    it "should set TTLs on all the keys" do
      Timecop.freeze(Time.now)

      expect {
        result
      }.to change {
        instances.map { |obj| redis.ttl(obj.class.send(:cache_key, obj.id)) }
      }.from([-2] * 4).to([TypicalModel.key_ttl_s] * 4)

      Timecop.return
    end

    it "calls the before_pantry_serialize" do
      expect(TypicalModel)
        .to receive(:before_pantry_serialize)
        .with(instances)
      result
    end

    context "when restocking the pantry" do
      before do
        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)
      end

      it "should add keys to cache index" do
        expect {
          result
        }.to change {
          redis.zcard(TypicalModel.send(:all_index_cache_key))
        }.from(0).to(4)
      end
    end
  end

  describe ".multi_store_by" do
    before do
      instances
      redis.flushall
    end

    let(:result) { TypicalModel.send(:multi_store_by, :team, ["backend"]) }
    let(:backend_team_index_key) do
      TypicalModel.send(:secondary_index_cache_key, :team, "backend")
    end

    it "populates secondary indices of given attribute for all given values" do
      result
      expect(redis.scard(backend_team_index_key)).to eq(3)
    end

    it "populates primary index for all objects it has retrieved" do
      result
      instances.each do |obj|
        if obj.team == "backend"
          expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
            .to eq(true)
        end
      end
    end

    context "with a non-unique secondary index" do
      it "returns a map from attribute value to array of indexed objects" do
        expect(result).to eq({
          "backend" => [instances[0], instances[2], instances[3]]
            .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) }
        })
      end
    end

    context "with a unique secondary index" do
      let(:result) { TypicalModel.send(:multi_store_by, :nickname, ["Lere"]) }

      it "returns a map from attribute value to indexed object" do
        expect(result).to eq({
          "Lere" => Pantry::DryGood.new(
            JSON.parse(instances[2].send(:pantry_json)))
        })
      end
    end
  end

  describe ".store" do
    let(:result) { TypicalModel.send(:store, instance.id) }

    before do
      expect(TypicalModel)
        .to receive(:multi_store)
        .with([instance], skip_deserialization: false)
        .and_return({
          instance.id => Pantry::DryGood.new(instance.pantry_attributes)
        })
    end

    it "should unpack the result of multi_store" do
      expect(result).to eq(Pantry::DryGood.new(instance.pantry_attributes))
    end
  end

  describe ".multi_invalidate" do
    let(:to_invalidate) { [] }
    let(:result) { TypicalModel.multi_invalidate(to_invalidate) }

    context "given an empty list of objects" do
      it "does nothing" do
        expect { result }.to_not raise_error
      end
    end

    context "given a non-empty list of objects" do
      let!(:to_invalidate) { instances }

      before do
        instances.each do |obj|
          redis.set(
            TypicalModel.send(:cache_key, obj.id),
            obj.send(:pantry_json))
        end
      end

      it "removes the identified objects from the cache" do
        result
        expect(redis.mget(to_invalidate.map { |obj| TypicalModel.send(:cache_key, obj.id) }))
          .to eq([nil] * to_invalidate.size)
      end

      context "when restocking the pantry" do
        before do
          allow(TypicalModel)
            .to receive(:restock?)
            .and_return(true)
        end

        it "writes the objects back to the cache" do
          result
          instances.each do |obj|
            expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
              .to eq(true)
          end
        end
      end
    end

    context "given a non-empty list of ids" do
      let!(:to_invalidate) { instances.map(&:id) }

      before do
        instances.each do |obj|
          redis.set(
            TypicalModel.send(:cache_key, obj.id),
            obj.send(:pantry_json))
        end
      end

      it "removes the identified objects from the cache" do
        expect(redis)
          .to receive(:del)
          .with(
            to_invalidate.map { |id| TypicalModel.send(:cache_key, id) })

        result
      end

      context "when restocking the pantry" do
        before do
          allow(TypicalModel)
            .to receive(:restock?)
            .and_return(true)
        end

        it "writes the objects back to the cache" do
          result
          instances.each do |obj|
            expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
              .to eq(true)
          end
        end
      end
    end

    context "with secondary indices" do

      context "when passed a list of objects" do
        let(:to_invalidate) { [instance] }

        before do
          allow(instance)
            .to receive(:previous_changes)
            .and_return({"team" => [nil, "backend"]})
        end

        it "destroys indices for old and new values of changed attributes" do
          previous_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            nil)
          new_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            "backend")

          result

          expect(redis.mget([previous_value_index_key, new_value_index_key]))
            .to eq([nil, nil])
        end
      end

      context "with a block for further scoping" do
        let(:to_invalidate) { [instances[0]] }

        before do
          allow(instances[0])
            .to receive(:previous_changes)
            .and_return({"nickname" => [nil, "Benji"]})
          result = TypicalModel.get_by(:team, "backend")

          TypicalModel.class_eval do
            stock_by(:team) { where.not(nickname: "Benji") }
          end
        end

        after do
          TypicalModel.class_eval { stock_by(:team) }
        end

        it "invalidates other attributes, even when they aren't updated" do
          before_invalidation = [instances[0], instances[2], instances[3]]
            .map(&:id)
          expect {
            result
          }.to change {
            TypicalModel.send(:multi_fetch_by, :team, ["backend"])
              .map { |_, values| values.map(&:id) }
              .flatten
          }.from(before_invalidation).to([])
        end
      end

      context "when passed a list of ids" do
        let(:to_invalidate) { [instance.id] }

        before do
          allow_any_instance_of(TypicalModel)
            .to receive(:previous_changes)
            .and_return({"team" => [nil, "backend"]})
        end

        it "destroys indices for old and new values of changed attributes" do
          previous_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            nil)
          new_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            "backend")

          result

          expect(redis.mget([previous_value_index_key, new_value_index_key]))
            .to eq([nil, nil])
        end
      end
    end
  end

  describe ".invalidate" do
    it "delegates to multi_invalidate" do
      expect(TypicalModel).to receive(:multi_invalidate).with([instance])
      TypicalModel.invalidate(instance)
    end
  end

  describe ".restock!" do
    it "should cache all the models" do
      allow(TypicalModel)
        .to receive(:restock?)
        .and_return(true)
      expect(TypicalModel)
        .to receive(:multi_store)
        .with(instances)
      TypicalModel.restock!
    end
  end

  describe ".tidy!" do
    context "with no index key" do
      it "should be a no-op" do
        expect { TypicalModel.tidy! }.to_not raise_error
      end
    end

    context "with the index fully populated" do
      let(:now) { Time.now }
      let(:result) { TypicalModel.multi_get_all }
      let(:keys_with_scores) do
        instances.map do |obj|
          [
            obj.id.even? ? now.to_i : (now.to_i - obj.id),
            obj.id.to_s
          ]
        end
      end

      before do
        # Configure the model to allow `multi_get_all`.
        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)

        # Set up cache index.
        redis.zadd(
          TypicalModel.send(:all_index_cache_key),
          keys_with_scores)

        Timecop.freeze(now)
      end

      after { Timecop.return }

      it "should expire old keys from index and leave unexpired ones in tact" do
        unexpired_keys = keys_with_scores.sort
          .reduce([]) do |memo, (score, key)|

          memo << key if score >= now.to_i
          memo
        end
        expect {
          TypicalModel.tidy!
        }.to change {
          redis.zrange(TypicalModel.send(:all_index_cache_key), 0, -1)
        }.from(keys_with_scores.sort.map { |_, key| key }).to(unexpired_keys)
      end
    end
  end

  describe ".cache_key" do
    it "should generate the right cache key" do
      expect(cache_key).to eq("pantry:v1:typicalmodel:v1:##{instance.id}")
    end
  end

  describe ".secondary_index_cache_key" do
    it "should generate the right cache key" do
      expect(
        TypicalModel.send(
          :secondary_index_cache_key,
          "my_index_attribute",
          "attribute_value"))
      .to eq(
        "pantry:v1:typicalmodel:v1:index:my_index_attribute:attribute_value")
    end

    context "when the given value is nil" do
      it "generates a special key that differentiates nil from empty string" do
        expect(
          TypicalModel.send(
            :secondary_index_cache_key,
            "my_index_attribute",
            nil))
        .to eq(
          "pantry:v1:typicalmodel:v1:index:my_index_attribute:__pantry_nil__")
      end
    end
  end

  describe "#pantry_attributes" do
    it "should return all attributes by default" do
      expect(instance.pantry_attributes.keys.sort).to eq([
        "created_at",
        "id",
        "name",
        "nickname",
        "team",
        "updated_at"
      ])
    end
  end
end
