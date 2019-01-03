require_dependency 'enum'
require_dependency 'reviewable/actions'
require_dependency 'reviewable/editable_fields'
require_dependency 'reviewable/perform_result'

class Reviewable < ActiveRecord::Base
  validates_presence_of :type, :status, :created_by_id
  belongs_to :target, polymorphic: true
  belongs_to :created_by, class_name: 'User'

  # Optional, for filtering
  belongs_to :topic
  belongs_to :category

  has_many :reviewable_histories

  after_create do
    log_history(:created, created_by)
  end

  def self.statuses
    @statuses ||= Enum.new(
      pending: 0,
      approved: 1,
      rejected: 2,
      ignored: 3,
      deleted: 4
    )
  end

  # Generate `pending?`, `rejected?` helper methods
  statuses.each do |name, id|
    define_method("#{name}?") { status == id }
  end

  # Create a new reviewable, or if the target has already been reviewed return it to the
  # pending state and re-use it.
  #
  # You probably want to call this to create your reviewable rather than `.create`.
  def self.needs_review!(target: nil, created_by:, payload: nil)
    create!(target: target, created_by: created_by)
  rescue ActiveRecord::RecordNotUnique
    where(target: target).update_all(status: statuses[:pending])
    find_by(target: target).tap { |r| r.log_history(:transitioned, created_by) }
  end

  def history
    reviewable_histories.order(:created_at)
  end

  def log_history(reviewable_history_type, performed_by, edited: nil)
    reviewable_histories.create!(
      reviewable_history_type: ReviewableHistory.types[reviewable_history_type],
      status: status,
      created_by: performed_by,
      edited: edited
    )
  end

  def actions_for(guardian, args = nil)
    args ||= {}
    Actions.new(self, guardian).tap { |a| build_actions(a, guardian, args) }
  end

  def editable_for(guardian, args = nil)
    args ||= {}
    EditableFields.new(self, guardian, args).tap { |a| build_editable_fields(a, guardian, args) }
  end

  # subclasses implement "build_actions" to list the actions they're capable of
  def build_actions(actions, guardian, args)
  end

  # subclasses implement "build_editable_fields" to list stuff that can be edited
  def build_editable_fields(actions, guardian, args)
  end

  def update_fields(params, performed_by)
    return true if params.blank?

    (params[:payload] || {}).each { |k, v| self.payload[k] = v }
    self.category_id = params[:category_id] if params.has_key?(:category_id)

    result = false

    Reviewable.transaction do
      changes_json = changes.as_json

      result = save
      log_history(:edited, performed_by, edited: changes_json) if result
    end

    result
  end

  # Delegates to a `perform_#{action_id}` method, which returns a `PerformResult` with
  # the result of the operation and whether the status of the reviewable changed.
  def perform(performed_by, action_id, args = nil)
    args ||= {}

    # Ensure the user has access to the action
    actions = actions_for(Guardian.new(performed_by), args)
    unless actions.has?(action_id)
      raise Discourse::InvalidAccess.new("Can't peform `#{action_id}` on #{self.class.name}")
    end

    perform_method = "perform_#{action_id}".to_sym
    raise "Invalid reviewable action `#{action_id}` on #{self.class.name}" unless respond_to?(perform_method)

    result = nil
    Reviewable.transaction do
      result = send(perform_method, performed_by, args)

      if result.success? && result.transition_to
        self.status = Reviewable.statuses[result.transition_to]
        save!
        log_history(:transitioned, performed_by)
      end
    end
    result
  end

  def self.bulk_perform_targets(performed_by, action, type, target_ids, args = nil)
    args ||= {}
    viewable_by(performed_by).where(type: type, target_id: target_ids).each do |r|
      r.perform(performed_by, action, args)
    end
  end

  def self.viewable_by(user)
    return none unless user.present?
    result = order('created_at desc').includes(:target, :created_by, :topic)
    return result if user.admin?

    result.where(
      '(reviewable_by_moderator AND :staff) OR (reviewable_by_group_id IN (:group_ids))',
      staff: user.staff?,
      group_ids: user.group_users.pluck(:group_id)
    )
  end

  def self.list_for(user, status: :pending)
    return [] if user.blank?
    viewable_by(user).where(status: statuses[status])
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
#  topic_id                :integer
#  target_id               :integer
#  target_type             :string
#  payload                 :json
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#
# Indexes
#
#  index_reviewables_on_status              (status)
#  index_reviewables_on_status_and_type     (status,type)
#  index_reviewables_on_type_and_target_id  (type,target_id) UNIQUE
#
