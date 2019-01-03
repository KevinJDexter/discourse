class Reviewable < ActiveRecord::Base
  class PerformResult
    include ActiveModel::Serialization

    attr_reader :status, :transition_to

    def initialize(status, args = nil)
      args ||= {}

      @status, @args = status
      @transition_to = args[:transition_to]
    end

    def success?
      @status == :success
    end
  end
end
