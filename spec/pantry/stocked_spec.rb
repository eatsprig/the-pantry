require "spec_helper"
require "support/schema"
require "support/typical_model"

describe Pantry::Stocked do
  def create_model
    TypicalModel.create!(
      name: "Olalere",
      nickname: "Lere",
      team: "backend"
    )
  end

  def create_models
    [
      TypicalModel.create!(
        name: "Matthew",
        nickname: "Matt",
        team: "backend"
      ),
      TypicalModel.create!(
        name: "Kyle",
        nickname: "Kyle",
        team: "client"
      ),
      TypicalModel.create!(
        name: "Olalere",
        nickname: "Lere",
        team: "backend"
      ),
      TypicalModel.create!(
        name: "Benjamin",
        nickname: "Benji",
        team: "backend"
      )
    ]
  end

  def cache_model(instance)
    cache_key = instance.class.send(:cache_key, instance.id)
    redis.set(cache_key, instance.send(:pantry_json))
  end

  def create_cached_model
    instance = create_model
    cache_model(instance)
    instance
  end

  def create_cached_models
    instances = create_models
    instances.each do |instance|
      cache_model(instance)
    end
    instances
  end

  def cache_all_models(instances, now)
    keys_with_scores = instances.map do |obj|
      [now.to_i + obj.class.key_ttl_s, obj.id]
    end
    redis.zadd(
      TypicalModel.send(:all_index_cache_key),
      keys_with_scores)
  end

  let(:redis) { Pantry.redis }

  context "after_commit" do
    it "invalidates the cache" do
      instance = create_cached_model

      expect(TypicalModel)
        .to receive(:invalidate)
        .with(instance)

      instance.run_callbacks(:commit)
    end

    context "on destroy with restock" do
      it "does not restock the model" do
        instance = create_cached_model

        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)
        expect(TypicalModel).to_not receive(:store)

        instance.destroy!
      end
    end
  end

  describe ".multi_get" do
    context "for a mixture of cache hits and misses" do
      it "fills in misses in returned results" do
        instances = create_models
        instances.each do |instance|
          if instance.id.even?
            cache_model(instance)
          end
        end

        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        result = TypicalModel.multi_get(instances.map(&:id))
        expect(result).to eq(expected)
      end

      it "writes misses to the cache" do
        instances = create_models
        instances.each do |instance|
          if instance.id.even?
            cache_model(instance)
          end
        end

        uncached = instances.find_all { |obj| obj.id.odd? }
        multi_store_response = uncached
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        expect(TypicalModel)
          .to receive(:multi_store)
          .with(uncached)
          .and_return(multi_store_response)
        TypicalModel.multi_get(instances.map(&:id))
      end

      it "casts times to Time objects" do
        instances = create_models
        result = TypicalModel.multi_get(instances.map(&:id))
        expect(result.values.first.created_at).to be_a(Time)
      end
    end

    context "on cache miss" do
      context "when ids are provided as strings" do
        it "returns strings (not integers) as keys in the result" do
          instance = create_model
          result = TypicalModel.multi_get([instance.id.to_s])

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
      context "when index is fully populated" do
        it "retrieves indexed records" do
          instances = create_models
          instances.each do |instance|
            cache_model(instance)
          end

          expected =
            {
              "backend" => [instances[0], instances[2], instances[3]].map do |o|
                  Pantry::DryGood.new(JSON.parse(o.send(:pantry_json)))
                end,
              "infrastructure" => []
            }
          result =
            TypicalModel.multi_get_by(
              :team,
              ["backend", "infrastructure"]
            )

          expect(result).to eq(expected)
        end

        context "when a new record is created" do
          it "updates index to include new record" do
            instances = create_models
            instances.each do |instance|
              cache_model(instance)
            end

            TypicalModel.multi_get_by(
              :team,
              ["backend", "infrastructure"]
            )

            new_instance = TypicalModel.create!(
              name: "Remi",
              nickname: "Remi",
              team: "backend"
            )
            result =
              TypicalModel.multi_get_by(
                :team,
                ["backend", "infrastructure"]
              )

            expect(result["backend"])
              .to include(Pantry::DryGood.new(
                JSON.parse(new_instance.send(:pantry_json))))
          end
        end
      end

      context "when index is not populated" do
        it "retrieves relevant records" do
          instances = create_models

          expected =
            {
              "backend" => [instances[0], instances[2], instances[3]].map do |o|
                Pantry::DryGood.new(JSON.parse(o.send(:pantry_json)))
              end,
              "infrastructure" => []
            }
          result =
            TypicalModel.multi_get_by(
              :team,
              ["backend", "infrastructure"]
            )

          expect(result).to eq(expected)
        end

        it "fills in the index as necessary" do
          instances = create_models
          backend_team_index_key =
            TypicalModel.send(:secondary_index_cache_key, :team, "backend")
          expected =
            {
              "backend" => [instances[0], instances[2], instances[3]].map do |o|
                Pantry::DryGood.new(JSON.parse(o.send(:pantry_json)))
              end,
              "infrastructure" => []
            }
          TypicalModel.multi_get_by(
            :team,
            ["backend", "infrastructure"]
          )
          expect(redis.smembers(backend_team_index_key).sort)
            .to eq(expected["backend"].map { |obj| obj.id.to_s })
        end

        context "when a block was given for the attribute" do
          before do
            TypicalModel.class_eval do
              stock_by(:team) { where.not(nickname: "Benji") }
            end
          end

          after do
            TypicalModel.class_eval { stock_by(:team) }
          end

          it "uses the block to further scope fetching from the database" do
            instances = create_models
            expected =
              {
                "backend" => [instances[0], instances[2]]
                               .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) },
                "infrastructure" => []
              }
            result =
              TypicalModel.multi_get_by(
                :team,
                ["backend", "infrastructure"]
              )

            expect(result).to eq(expected)
          end

          context "when a record is updated that removes it from the scope" do
            it "properly invalidates and then refetches correct objects" do
              instances = create_models
              expected =
                {
                  "backend" => [instances[0]]
                                 .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) },
                  "infrastructure" => []
                }
              # fetch before we make the change to load all instances
              TypicalModel.multi_get_by(
                :team,
                ["backend", "infrastructure"])
              instances[2].update!(nickname: "Benji")
              result = TypicalModel.multi_get_by(
                :team,
                ["backend", "infrastructure"])

              expect(result).to eq(expected)
            end
          end
        end
      end
    end

    context "for a unique index" do
      context "when index is fully populated" do
        it "retrieves indexed records" do
          instances = create_models
          result =
            TypicalModel.multi_get_by(:nickname, ["Lere", "Matt", "Jes"])
          expected =
            [instances[0], instances[2]]
              .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
              .index_by(&:nickname)
          expected["Jes"] = nil

          expect(result).to eq(expected)
        end
      end

      context "when index is only partially populated" do
        it "retrieves relevant records" do
          instances = create_models
          nickname_key =
            TypicalModel.send(:secondary_index_cache_key, :nickname, "Lere")
          redis.del(nickname_key)

          result =
            TypicalModel.multi_get_by(:nickname, ["Lere", "Matt", "Jes"])
          expected =
            [instances[0], instances[2]]
              .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
              .index_by(&:nickname)
          expected["Jes"] = nil

          expect(result).to eq(expected)
        end

        it "fills in the index as necessary" do
          create_models
          nickname_key =
            TypicalModel.send(:secondary_index_cache_key, :nickname, "Lere")
          TypicalModel.multi_get_by(:nickname, ["Lere", "Matt", "Jes"])

          expect(redis.scard(nickname_key)).to eq(1)
        end
      end
    end
  end

  describe ".get" do
    it "unpacks the result of a multi_get" do
      instance = create_model
      expect(TypicalModel)
        .to receive(:multi_get)
        .with([instance.id])
        .and_return({
          instance.id => Pantry::DryGood.new(instance.pantry_attributes)
         })
      result = TypicalModel.get(instance.id)
      expect(result).to eq(Pantry::DryGood.new(instance.pantry_attributes))
    end
  end

  describe ".get_by" do
    context "for a non-unique index" do
      it "retrieves indexed records" do
        instances = create_models
        result = TypicalModel.get_by(:team, "backend")
        expected = [instances[0], instances[2], instances[3]]
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
        expect(result).to eq(expected)
      end

      context "when index entry exists but object has been deleted" do
        it "does not return that object" do
          instances = create_models
          instances[0].destroy!
          result = TypicalModel.get_by(:team, "backend")

          expected = [instances[2], instances[3]].map do |obj|
            Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json)))
          end

          expect(result).to eq(expected)
        end
      end
    end

    context "for a unique index" do
      it "retrieves an indexed record" do
        instance = create_model
        result = TypicalModel.get_by(:nickname, "Lere")
        expect(result).to eq(
          Pantry::DryGood.new(JSON.parse(instance.send(:pantry_json))))
      end

      context "when index entry exists but object has been deleted" do
        it "returns nil" do
          instance = create_model
          instance.destroy!
          result = TypicalModel.get_by(:nickname, "Lere")
          expect(result).to be_nil
        end
      end
    end
  end

  describe ".multi_get_all" do
    before do
      # Configure the model to allow `multi_get_all`.
      allow(TypicalModel)
        .to receive(:restock?)
        .and_return(true)
    end

    context "with the index fully populated" do
      it "fetches all cached models" do
        instances = create_models
        instances.each do |instance|
          cache_model(instance)
        end
        now = Time.now
        cache_all_models(instances, now)

        Timecop.freeze(now) do
          expected = instances
            .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
            .index_by(&:id)
          result = TypicalModel.multi_get_all
          expect(result).to eq(expected)
        end
      end
    end

    context "with expired keys" do
      it "fetches only unexpired cached models" do
        valid_instance = create_cached_model
        expired_instance = create_cached_model
        now = Time.now
        redis.zadd(
          TypicalModel.send(:all_index_cache_key),
          [
            [now.to_i + valid_instance.class.key_ttl_s, valid_instance.id],
            [now.to_i - 123, expired_instance.id],
          ]
        )

        Timecop.freeze(now) do
          expected = [valid_instance]
                       .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
                       .index_by(&:id)
          result = TypicalModel.multi_get_all
          expect(result).to eq(expected)
        end
      end
    end

    context "without an index key (equivalent to empty index key)" do
      it "fetches all models from the database" do
        instances = create_models
        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        result = TypicalModel.multi_get_all
        expect(result).to eq(expected)
      end

      it "populates the index key" do
        expect {
          create_models
          TypicalModel.multi_get_all
        }.to change {
          redis.zcard(TypicalModel.send(:all_index_cache_key))
        }.from(0).to(4)
      end
    end

    context "when configured to force cache misses" do
      before { Pantry.configuration.force_cache_misses = true }
      after { Pantry.configuration.force_cache_misses = false }

      it "fetches all models (from the database)" do
        instances = create_models
        expected = instances
          .map { |obj| Pantry::DryGood.new(JSON.parse(obj.send(:pantry_json))) }
          .index_by(&:id)
        result = TypicalModel.multi_get_all
        expect(result).to eq(expected)
      end
    end
  end

  describe ".multi_fetch" do
    context "when configured to force cache misses" do
      before { Pantry.configuration.force_cache_misses = true }
      after { Pantry.configuration.force_cache_misses = false }

      it "returns a hash of only nil values" do
        instances = create_models
        result = TypicalModel.send(:multi_fetch, instances.map(&:id))

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
        it "returns a hash of only empty arrays" do
          instances = create_models
          teams = instances.map(&:team).uniq.sort
          result =
            TypicalModel.send(
              :multi_fetch_by,
              "team",
              instances.map(&:team).uniq
            )

          expect(result.keys.sort).to eq(teams)
          expect(result.values).to eq([[]] * teams.length)
        end
      end

      context "for a unique index" do
        it "returns a hash of only empty nil values" do
          instances = create_models
          nicknames = instances.map(&:nickname).uniq.sort
          result =
            TypicalModel.send(
              :multi_fetch_by,
              "nickname",
              instances.map(&:nickname).uniq
            )

          expect(result.keys.sort).to eq(nicknames)
          expect(result.values).to eq([nil] * nicknames.length)
        end
      end
    end
  end

  describe ".dry_good_type" do
    context "when type is left as default" do
      it "returns a DryGood" do
        instance = create_model
        result = TypicalModel.get(instance.id)
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

      it "returns the custom type" do
        instance = create_model
        result = TypicalModel.get(instance.id)
        expect(result.class).to be(TypicalModel)
      end
    end
  end

  describe ".multi_store" do
    it "writes keys to the cache" do
      instances = create_models
      redis.flushall # clear the cache
      expect {
        TypicalModel.send(:multi_store, instances)
      }.to change {
        redis.mget(instances.map { |obj| obj.class.send(:cache_key, obj.id) })
      }.from([nil] * 4).to(instances.map { |obj| obj.send(:pantry_json) })
    end

    it "sets TTLs on all the keys" do
      instances = create_models
      redis.flushall # clear the cache

      Timecop.freeze(Time.now) do
        expect {
          TypicalModel.send(:multi_store, instances)
        }.to change {
          instances.map { |obj| redis.ttl(obj.class.send(:cache_key, obj.id)) }
        }.from([-2] * 4).to([TypicalModel.key_ttl_s] * 4)
      end
    end

    it "calls the before_pantry_serialize" do
      instances = create_models
      redis.flushall # clear the cache

      expect(TypicalModel)
        .to receive(:before_pantry_serialize)
        .with(instances)
      TypicalModel.send(:multi_store, instances)
    end

    context "when restocking the pantry" do
      it "adds keys to cache index" do
        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)
        instances = create_models
        redis.flushall # clear the cache

        expect {
          TypicalModel.send(:multi_store, instances)
        }.to change {
          redis.zcard(TypicalModel.send(:all_index_cache_key))
        }.from(0).to(4)
      end
    end
  end

  describe ".multi_store_by" do
    it "populates secondary indices of given attribute for all given values" do
      create_models
      redis.flushall # clear the cache

      TypicalModel.send(:multi_store_by, :team, ["backend"])
      backend_team_index_key =
        TypicalModel.send(:secondary_index_cache_key, :team, "backend")
      expect(redis.scard(backend_team_index_key)).to eq(3)
    end

    it "populates primary index for all objects it has retrieved" do
      instances = create_models
      redis.flushall # clear the cache

      TypicalModel.send(:multi_store_by, :team, ["backend"])
      instances.each do |obj|
        if obj.team == "backend"
          expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
            .to eq(true)
        end
      end
    end

    context "with a non-unique secondary index" do
      it "returns a map from attribute value to array of indexed objects" do
        instances = create_models
        redis.flushall # clear the cache

        result = TypicalModel.send(:multi_store_by, :team, ["backend"])
        expect(result).to eq({
          "backend" => [instances[0], instances[2], instances[3]]
            .map { |o| Pantry::DryGood.new(JSON.parse(o.send(:pantry_json))) }
        })
      end
    end

    context "with a unique secondary index" do
      it "returns a map from attribute value to indexed object" do
        instances = create_models
        redis.flushall # clear the cache

        result = TypicalModel.send(:multi_store_by, :nickname, ["Lere"])
        expect(result).to eq({
          "Lere" => Pantry::DryGood.new(
            JSON.parse(instances[2].send(:pantry_json)))
        })
      end
    end
  end

  describe ".store" do
    it "unpacks the result of multi_store" do
      instance = create_model
      expect(TypicalModel)
        .to receive(:multi_store)
        .with([instance], skip_deserialization: false)
        .and_return({
          instance.id => Pantry::DryGood.new(instance.pantry_attributes)
        })
      result = TypicalModel.send(:store, instance.id)
      expect(result).to eq(Pantry::DryGood.new(instance.pantry_attributes))
    end
  end

  describe ".multi_invalidate" do
    context "given an empty list of objects" do
      it "does nothing" do
        expect {
          TypicalModel.multi_invalidate([])
        }.to_not raise_error
      end
    end

    context "given a non-empty list of objects" do
      it "removes the identified objects from the cache" do
        instances = create_cached_models
        TypicalModel.multi_invalidate(instances)
        expect(redis.mget(instances.map { |obj| TypicalModel.send(:cache_key, obj.id) }))
          .to eq([nil] * instances.size)
      end

      context "when restocking the pantry" do
        it "writes the objects back to the cache" do
          allow(TypicalModel)
            .to receive(:restock?)
            .and_return(true)
          instances = create_cached_models
          TypicalModel.multi_invalidate(instances)
          instances.each do |obj|
            expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
              .to eq(true)
          end
        end
      end
    end

    context "given a non-empty list of ids" do
      it "removes the identified objects from the cache" do
        instances = create_cached_models

        expect(redis)
          .to receive(:del)
          .with(
            instances.map(&:id).map { |id| TypicalModel.send(:cache_key, id) })

        TypicalModel.multi_invalidate(instances.map(&:id))
      end

      context "when restocking the pantry" do
        it "writes the objects back to the cache" do
          allow(TypicalModel)
            .to receive(:restock?)
            .and_return(true)
          instances = create_cached_models
          TypicalModel.multi_invalidate(instances.map(&:id))
          instances.each do |obj|
            expect(redis.exists(TypicalModel.send(:cache_key, obj.id)))
              .to eq(true)
          end
        end
      end
    end

    context "with secondary indices" do
      context "when passed a list of objects" do
        it "destroys indices for old and new values of changed attributes" do
          instance = create_model
          allow(instance)
            .to receive(:previous_changes)
            .and_return({"team" => [nil, "backend"]})
          previous_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            nil)
          new_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            "backend")

          TypicalModel.multi_invalidate([instance])

          expect(redis.mget([previous_value_index_key, new_value_index_key]))
            .to eq([nil, nil])
        end
      end

      context "with a block for further scoping" do
        before do
          TypicalModel.class_eval do
            stock_by(:team) { where.not(nickname: "Benji") }
          end
        end

        after do
          TypicalModel.class_eval { stock_by(:team) }
        end

        it "invalidates other attributes, even when they aren't updated" do
          instances = create_models
          allow(instances[0])
            .to receive(:previous_changes)
            .and_return({"nickname" => [nil, "Benji"]})
          TypicalModel.get_by(:team, "backend")

          before_invalidation = [instances[0], instances[2]]
            .map(&:id)
          expect {
            TypicalModel.multi_invalidate([instances[0]])
          }.to change {
            TypicalModel.send(:multi_fetch_by, :team, ["backend"])
              .map { |_, values| values.map(&:id) }
              .flatten
          }.from(before_invalidation).to([])
        end
      end

      context "when passed a list of ids" do
        it "destroys indices for old and new values of changed attributes" do
          instance = create_model
          allow_any_instance_of(TypicalModel)
            .to receive(:previous_changes)
            .and_return({"team" => [nil, "backend"]})
          previous_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            nil)
          new_value_index_key = TypicalModel.send(
            :secondary_index_cache_key,
            :team,
            "backend")

          TypicalModel.multi_invalidate([instance.id])

          expect(redis.mget([previous_value_index_key, new_value_index_key]))
            .to eq([nil, nil])
        end
      end
    end
  end

  describe ".invalidate" do
    it "delegates to multi_invalidate" do
      instance = create_model
      expect(TypicalModel).to receive(:multi_invalidate).with([instance])
      TypicalModel.invalidate(instance)
    end
  end

  describe ".restock!" do
    it "caches all the models" do
      instances = create_models
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
      it "is a no-op" do
        expect { TypicalModel.tidy! }.to_not raise_error
      end
    end

    context "with the index fully populated" do
      it "expires old keys from index and leave unexpired ones in tact" do
        # Configure the model to allow `multi_get_all`.
        allow(TypicalModel)
          .to receive(:restock?)
          .and_return(true)

        instances = create_models
        now = Time.now

        keys_with_scores =
          instances.map do |obj|
            [
              obj.id.even? ? now.to_i : (now.to_i - obj.id),
              obj.id.to_s
            ]
          end

        # Set up cache index.
        redis.zadd(
          TypicalModel.send(:all_index_cache_key),
          keys_with_scores)
        unexpired_keys =
          keys_with_scores.sort.reduce([]) do |memo, (score, key)|
            memo << key if score >= now.to_i
            memo
          end

        expect {
          Timecop.freeze(now) do
            TypicalModel.tidy!
          end
        }.to change {
          redis.zrange(TypicalModel.send(:all_index_cache_key), 0, -1)
        }.from(keys_with_scores.sort.map { |_, key| key }).to(unexpired_keys)
      end
    end
  end

  describe ".cache_key" do
    it "generates the right cache key" do
      instance = create_model
      cache_key = TypicalModel.send(:cache_key, instance.id)
      expect(cache_key).to eq("pantry:v1:typicalmodel:v1:##{instance.id}")
    end
  end

  describe ".secondary_index_cache_key" do
    it "generates the right cache key" do
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
    it "returns all attributes by default" do
      instance = create_model
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
