class Reviewable < ActiveRecord::Base
  class PerformResult
    include ActiveModel::Serialization

    attr_reader :status, :transition_to, :post, :topic

    def initialize(status, transition_to: nil, post: nil)
      @status = status
      @transition_to = transition_to

      if post
        @post = post
        @topic = post.topic
      end
    end

    def success?
      @status == :success
    end
  end
end
