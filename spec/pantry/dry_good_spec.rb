require "spec_helper"
require "support/schema"
require "support/typical_model"

describe Pantry::DryGood do
  let(:instance) { TypicalModel.create!(name: "Olalere", nickname: "Lere") }
  let(:dry_good) { Pantry::DryGood.new(JSON.parse(instance.send(:pantry_json))) }

  describe "#to_json" do
    it "should not be wrapped in a key named table" do
      dry_good_json = JSON.parse(dry_good.to_json)
      expect(dry_good_json.keys).not_to include('table')
    end
  end

end