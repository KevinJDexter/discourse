require_dependency 'reviewable/collection'

class Reviewable < ActiveRecord::Base
  class Actions < Reviewable::Collection

    def self.common_actions
      {
        approve: Action.new(:approve, 'thumbs-up', 'reviewables.actions.approve.title'),
        reject: Action.new(:reject, 'thumbs-down', 'reviewables.actions.reject.title')
      }
    end

    class Action < Item
      attr_reader :icon, :title

      def initialize(id, icon, title)
        super(id)
        @icon, @title = icon, title
      end
    end

    def add(id)
      @content << Actions.common_actions[id] || Action.new(id, nil, nil)
    end
  end
end
