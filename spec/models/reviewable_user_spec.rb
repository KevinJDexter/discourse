require 'rails_helper'

RSpec.describe ReviewableUser, type: :model do

  before do
    SiteSetting.must_approve_users = true
  end

  describe '.approve' do
    let(:user) { Fabricate(:user) }
    let(:admin) { Fabricate(:admin) }

    context "email jobs" do
      before do
        user
      end

      after do
        ReviewableUser.find_by(target: user).perform(admin, :approve)
      end

      it "enqueues a 'signup after approval' email if must_approve_users is true" do
        Jobs.expects(:enqueue).with(
          :critical_user_email, has_entries(type: :signup_after_approval)
        )
      end

      it "doesn't enqueue a 'signup after approval' email if must_approve_users is false" do
        SiteSetting.must_approve_users = false
        Jobs.expects(:enqueue).never
      end
    end

    it 'triggers a extensibility event' do
      user && admin # bypass the user_created event
      event = DiscourseEvent.track_events {
        ReviewableUser.find_by(target: user).perform(admin, :approve)
      }.first

      expect(event[:event_name]).to eq(:user_approved)
      expect(event[:params].first).to eq(user)
    end

    context 'after approval' do
      it 'marks the user as approved' do
        ReviewableUser.find_by(target: user).perform(admin, :approve)
        user.reload
        expect(user).to be_approved
        expect(user.approved_by).to eq(admin)
        expect(user.approved_at).to be_present
      end
    end
  end

end
