class ReviewablePerformResultSerializer < ApplicationSerializer
  attributes :success, :transition_to, :transition_to_id

  def success
    object.success?
  end

  def transition_to_id
    Reviewable.statuses[transition_to]
  end
end
