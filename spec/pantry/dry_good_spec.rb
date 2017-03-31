require "spec_helper"
require "support/schema"
require "support/typical_model"

describe Pantry::DryGood do
  describe "#to_json" do
    it "is not wrapped in a key named table" do
      instance = TypicalModel.create!(
        name: "Olalere",
        nickname: "Lere"
      )
      dry_good = Pantry::DryGood.new(JSON.parse(instance.send(:pantry_json)))
      dry_good_json = JSON.parse(dry_good.to_json)

      expect(dry_good_json.keys).not_to include("table")
    end
  end
end
