require_dependency 'reviewable'

class ReviewableQueuedPost < Reviewable

  def build_actions(actions, guardian, args)
    return unless pending?

    actions.add(:approve) if guardian.is_staff?
    actions.add(:reject) if guardian.is_staff?
  end

  def build_editable_fields(fields, guardian, args)
    return unless guardian.is_staff?

    # We can edit category / title if it's a new topic
    if topic_id.blank?
      fields.add('category_id', :category)
      fields.add('payload.title', :text)
    end

    fields.add('payload.raw', :editor)
  end

end

# == Schema Information
#
# Table name: reviewables
#
#  id                      :bigint(8)        not null, primary key
#  type                    :string           not null
#  status                  :integer          default(0), not null
#  created_by_id           :integer          not null
#  reviewable_by_moderator :boolean          default(FALSE), not null
#  reviewable_by_group_id  :integer
#  claimed_by_id           :integer
#  category_id             :integer
#  target_id               :integer
#  target_type             :string
#  payload                 :json
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  topic_id                :integer
#
# Indexes
#
#  index_reviewables_on_status              (status)
#  index_reviewables_on_status_and_type     (status,type)
#  index_reviewables_on_type_and_target_id  (type,target_id) UNIQUE
#
