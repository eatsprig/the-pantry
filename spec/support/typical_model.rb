class TypicalModel < ActiveRecord::Base
  include Pantry::Stocked

  stock_by :nickname, unique: true
  stock_by :team
end
