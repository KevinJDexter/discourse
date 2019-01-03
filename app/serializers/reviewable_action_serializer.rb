class ReviewableActionSerializer < ApplicationSerializer
  attributes :id, :icon, :title

  def title
    I18n.t(object.title)
  end
end
